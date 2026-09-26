// Suite F (stack), F-NET-05: can this container reach Kafka the way its
// application does? Run by test/container/stack-probe.sh inside a live service
// container, in source-file mode, with the application's own classpath:
//
//     java -cp "$(cat /app/target/dev-classpath.txt)" KafkaProbe.java kafka:9092
//
// With kafka-clients on that classpath it builds an AdminClient and asks for
// describeCluster, which proves more than a TCP connect: the bootstrap name
// resolves, the broker speaks the protocol, and the listener it ADVERTISES
// back is one the other containers can use (a broker advertising localhost
// accepts the bootstrap connection and then sends every client to itself).
// Without kafka-clients - a service with no Kafka code - it falls back to a
// plain TCP connect, and says so.
//
// Everything Kafka is reached by reflection, so this file compiles and runs
// with nothing but the JDK; the classes come from whatever -cp provides.
//
// Output is ONE verdict line on stdout, which stack-probe.sh turns into a
// result:
//
//     KAFKAPROBE OK mode=adminclient ...     KAFKAPROBE OK mode=tcp ...
//     KAFKAPROBE FAIL mode=<adminclient|tcp|usage> ...
//
// Exit status: 0 = OK, 1 = FAIL, 2 = usage. Every wait is bounded by
// TIMEOUT_MS, so the probe cannot hang the suite.

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import java.util.Locale;
import java.util.Properties;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;

public class KafkaProbe {

    static final int TIMEOUT_MS = 10_000;

    public static void main(String[] args) {
        if (args.length != 1 || args[0].isBlank()) {
            System.out.println("KAFKAPROBE FAIL mode=usage usage: java KafkaProbe.java <host:port>[,<host:port>...]");
            System.exit(2);
        }
        String bootstrap = args[0].trim();
        Class<?> admin = find("org.apache.kafka.clients.admin.Admin", "org.apache.kafka.clients.admin.AdminClient");
        int rc;
        if (admin != null) {
            quietLogging();
            rc = adminClient(admin, bootstrap);
        } else {
            rc = tcp(bootstrap);
        }
        System.out.flush();
        // The client's own threads must not keep the JVM - and docker exec -
        // alive after the verdict.
        System.exit(rc);
    }

    // The first class of the list that the classpath has, or null.
    static Class<?> find(String... names) {
        for (String n : names) {
            try {
                return Class.forName(n, false, KafkaProbe.class.getClassLoader());
            } catch (ClassNotFoundException | LinkageError e) {
                // try the next one
            }
        }
        return null;
    }

    // A Spring Boot classpath carries logback, which with no configuration of
    // its own logs everything at DEBUG to stdout: hundreds of AdminClient
    // lines around the one line that matters. Best effort; any failure here
    // only means more noise.
    static void quietLogging() {
        try {
            Class<?> factory = Class.forName("org.slf4j.LoggerFactory");
            Object root = factory.getMethod("getLogger", String.class).invoke(null, "ROOT");
            Class<?> level = Class.forName("ch.qos.logback.classic.Level");
            Object warn = level.getField("WARN").get(null);
            root.getClass().getMethod("setLevel", level).invoke(root, warn);
        } catch (Throwable ignored) {
            // not logback, or not the version this expects
        }
    }

    static int adminClient(Class<?> adminType, String bootstrap) {
        long t0 = System.nanoTime();
        Properties p = new Properties();
        p.put("bootstrap.servers", bootstrap);
        p.put("client.id", "hc-stack-probe");
        p.put("request.timeout.ms", String.valueOf(TIMEOUT_MS));
        p.put("default.api.timeout.ms", String.valueOf(TIMEOUT_MS));
        // One attempt per address, not the default reconnect backoff loop:
        // the verdict should arrive well inside the timeout either way.
        p.put("reconnect.backoff.max.ms", "1000");
        Object client = null;
        try {
            ClassLoader cl = adminType.getClassLoader();
            client = adminType.getMethod("create", Properties.class).invoke(null, p);
            Object result = adminType.getMethod("describeCluster").invoke(client);
            Class<?> resultType = Class.forName("org.apache.kafka.clients.admin.DescribeClusterResult", true, cl);
            Class<?> futureType = Class.forName("org.apache.kafka.common.KafkaFuture", true, cl);
            Method get = futureType.getMethod("get", long.class, TimeUnit.class);
            long left = remaining(t0);
            Object clusterId = get.invoke(resultType.getMethod("clusterId").invoke(result), left, TimeUnit.MILLISECONDS);
            left = remaining(t0);
            Object nodes = get.invoke(resultType.getMethod("nodes").invoke(result), left, TimeUnit.MILLISECONDS);

            List<String> advertised = new ArrayList<>();
            List<String> loopback = new ArrayList<>();
            if (nodes instanceof Collection<?> c) {
                for (Object node : c) {
                    String hp = hostPort(node);
                    advertised.add(hp);
                    if (isLoopback(hp)) {
                        loopback.add(hp);
                    }
                }
            }
            long ms = elapsed(t0);
            if (advertised.isEmpty()) {
                System.out.println("KAFKAPROBE FAIL mode=adminclient bootstrap=" + bootstrap
                        + " describeCluster returned no broker ms=" + ms);
                return 1;
            }
            if (!loopback.isEmpty()) {
                System.out.println("KAFKAPROBE FAIL mode=adminclient bootstrap=" + bootstrap
                        + " the broker advertises " + String.join(",", loopback)
                        + ", a loopback address no other container can use (clusterId=" + clusterId + ") ms=" + ms);
                return 1;
            }
            System.out.println("KAFKAPROBE OK mode=adminclient bootstrap=" + bootstrap + " clusterId=" + clusterId
                    + " brokers=" + advertised.size() + " advertised=" + String.join(",", advertised) + " ms=" + ms);
            return 0;
        } catch (Throwable e) {
            Throwable t = unwrap(e);
            // The JDK's TimeoutException carries no message; the client's own
            // WARN lines above the verdict say what it was stuck on.
            String why = t instanceof java.util.concurrent.TimeoutException
                    ? "describeCluster got no answer within " + TIMEOUT_MS + " ms (see the client's WARN lines above)"
                    : describe(t);
            System.out.println("KAFKAPROBE FAIL mode=adminclient bootstrap=" + bootstrap + " " + why
                    + " ms=" + elapsed(t0));
            return 1;
        } finally {
            close(adminType, client);
        }
    }

    static int tcp(String bootstrap) {
        long t0 = System.nanoTime();
        String first = bootstrap.split(",")[0].trim();
        int colon = first.lastIndexOf(':');
        int port;
        try {
            port = Integer.parseInt(first.substring(colon + 1));
        } catch (RuntimeException e) {
            System.out.println("KAFKAPROBE FAIL mode=usage '" + first + "' is not host:port");
            return 2;
        }
        String host = first.substring(0, colon);
        if (host.startsWith("[") && host.endsWith("]")) {
            host = host.substring(1, host.length() - 1);
        }
        try (Socket s = new Socket()) {
            s.connect(new InetSocketAddress(host, port), TIMEOUT_MS);
            System.out.println("KAFKAPROBE OK mode=tcp connected to " + host + ":" + port + " ("
                    + s.getInetAddress().getHostAddress() + ") ms=" + elapsed(t0));
            return 0;
        } catch (Exception e) {
            System.out.println("KAFKAPROBE FAIL mode=tcp " + host + ":" + port + " " + describe(e) + " ms=" + elapsed(t0));
            return 1;
        }
    }

    static String hostPort(Object node) {
        try {
            Object host = node.getClass().getMethod("host").invoke(node);
            Object port = node.getClass().getMethod("port").invoke(node);
            return host + ":" + port;
        } catch (ReflectiveOperationException | RuntimeException e) {
            return String.valueOf(node);
        }
    }

    static boolean isLoopback(String hostPort) {
        String h = hostPort.toLowerCase(Locale.ROOT);
        int colon = h.lastIndexOf(':');
        if (colon > 0) {
            h = h.substring(0, colon);
        }
        h = h.replace("[", "").replace("]", "");
        return h.equals("localhost") || h.startsWith("127.") || h.equals("::1") || h.equals("0.0.0.0")
                || h.equals("host.docker.internal");
    }

    static void close(Class<?> adminType, Object client) {
        if (client == null) {
            return;
        }
        try {
            adminType.getMethod("close", Duration.class).invoke(client, Duration.ofSeconds(2));
        } catch (Throwable e) {
            try {
                adminType.getMethod("close").invoke(client);
            } catch (Throwable ignored) {
                // exiting anyway
            }
        }
    }

    // Reflection and futures each wrap the real failure once more.
    static Throwable unwrap(Throwable e) {
        Throwable t = e;
        for (int i = 0; i < 10 && t != null; i++) {
            if (t instanceof InvocationTargetException ite && ite.getTargetException() != null) {
                t = ite.getTargetException();
            } else if (t instanceof ExecutionException && t.getCause() != null) {
                t = t.getCause();
            } else {
                break;
            }
        }
        return t == null ? e : t;
    }

    static String describe(Throwable t) {
        StringBuilder sb = new StringBuilder();
        Throwable c = t;
        for (int i = 0; i < 4 && c != null; i++) {
            if (i > 0) {
                sb.append(" <- ");
            }
            sb.append(c.getClass().getName());
            if (c.getMessage() != null) {
                sb.append(": ").append(c.getMessage());
            }
            c = c.getCause() == c ? null : c.getCause();
        }
        return sb.toString().replaceAll("[\\r\\n\\t]+", " ");
    }

    static long elapsed(long t0) {
        return TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - t0);
    }

    static long remaining(long t0) {
        return Math.max(1, TIMEOUT_MS - elapsed(t0));
    }
}
