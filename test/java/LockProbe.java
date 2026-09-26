/*
 * Suite D (concurrency): the two halves of the D-LOCK tests, on the resolver's
 * own lock files.
 *
 *     java LockProbe.java hold  <lock file> <seconds> [stop file]
 *     java LockProbe.java probe <locks dir> <seconds> [stop file]
 *
 * Both run in a container of the isolated test project, on the shared Maven
 * volume, next to a container running a real Maven build. Single file, JDK
 * only; the lock calls are exactly the ones resolver 1.9's FileLockNamedLock
 * makes - FileChannel.lock / tryLock on the region (0, 1) - which on Linux are
 * fcntl record locks, kept per inode by the one kernel every container shares.
 *
 * hold: opens the file READ, WRITE, CREATE, takes an EXCLUSIVE lock on (0, 1),
 * prints "HELD <file>", and keeps it for <seconds> or until the stop file
 * appears, then releases it and prints "RELEASED <file>". A Maven build that
 * needs that artifact must now fail with "Could not acquire" once its
 * aether.syncContext.named.time runs out - and succeed once this has gone.
 *
 * probe: the REVERSE direction, and the one that tells deleteLockFiles=false
 * apart from the default. Holding a file ourselves proves little: Maven opens
 * the path we hold and meets our inode whatever its settings. What the setting
 * changes is what happens to the file MAVEN creates: with DELETE_ON_CLOSE the
 * JDK unlinks it the moment it is opened, so another process can never find
 * it, creates its own, and the two lock different inodes. So this repeatedly
 * lists <locks dir>, opens every EXISTING *.lock - READ, WRITE, and never
 * CREATE, so it only ever meets a file somebody else made - and tries an
 * exclusive lock on it. A try that fails is Maven, in another container,
 * holding that very inode: the lock works across processes. Each lock taken
 * is released at once, and the loop sleeps 10 ms between passes, so the build
 * it watches is delayed by at most one of the resolver's 100 ms retries.
 *
 * It ends after <seconds>, when the stop file appears, or on SIGTERM, and
 * always prints, as its last line:
 *
 *     CONTENDED=<n> SEEN=<m>
 *
 * n = tries that found the file locked by another process, m = distinct lock
 * files seen. A "PROBE ..." line before it has the rest of the counts.
 *
 * Exit status: 0 = ran; 1 = could not take or keep the lock (hold); 2 = usage.
 */

import java.io.IOException;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.channels.OverlappingFileLockException;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.NoSuchFileException;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.TreeSet;
import java.util.concurrent.atomic.AtomicBoolean;

public class LockProbe {

    public static void main(String[] args) throws Exception {
        if (args.length < 3 || args.length > 4) {
            usage();
        }
        long secs = parseSeconds(args[2]);
        Path stop = args.length == 4 ? Paths.get(args[3]) : null;
        switch (args[0]) {
            case "hold":
                System.exit(hold(Paths.get(args[1]), secs, stop));
                break;
            case "probe":
                System.exit(new Prober(Paths.get(args[1])).run(secs, stop));
                break;
            default:
                usage();
        }
    }

    private static void usage() {
        System.err.println("usage: java LockProbe.java hold <lock file> <seconds> [stop file]");
        System.err.println("       java LockProbe.java probe <locks dir> <seconds> [stop file]");
        System.exit(2);
    }

    private static long parseSeconds(String s) {
        try {
            long v = Long.parseLong(s);
            if (v > 0) {
                return v;
            }
        } catch (NumberFormatException e) {
            // reported below
        }
        System.err.println("seconds must be a whole number above zero, not '" + s + "'");
        System.exit(2);
        return 0;
    }

    private static boolean due(long deadline, Path stop) {
        return System.nanoTime() - deadline >= 0 || (stop != null && Files.exists(stop));
    }

    private static int hold(Path file, long secs, Path stop) throws InterruptedException {
        try {
            Path parent = file.toAbsolutePath().getParent();
            if (parent != null && !Files.isDirectory(parent)) {
                Files.createDirectories(parent);
                System.out.println("created " + parent);
            }
            try (FileChannel ch = FileChannel.open(file, StandardOpenOption.READ, StandardOpenOption.WRITE, StandardOpenOption.CREATE)) {
                System.out.println("LOCKING " + file);
                System.out.flush();
                // Blocking on purpose: if a build holds it right now, wait for
                // it rather than report a hold that never happened.
                try (FileLock lock = ch.lock(0, 1, false)) {
                    System.out.println("HELD " + file + (lock.isShared() ? " (shared - not what was asked for)" : " (exclusive)"));
                    System.out.flush();
                    long deadline = System.nanoTime() + secs * 1_000_000_000L;
                    while (!due(deadline, stop)) {
                        Thread.sleep(200);
                    }
                }
            }
        } catch (IOException e) {
            System.out.println("HOLD-FAILED " + file + ": " + e);
            return 1;
        }
        System.out.println("RELEASED " + file);
        return 0;
    }

    private static final class Prober {
        private final Path dir;
        private final Set<String> seen = new TreeSet<>();
        private final Set<String> contendedFiles = new TreeSet<>();
        private volatile long contended;
        private volatile long free;
        private volatile long vanished;
        private volatile long errors;
        private volatile long rounds;
        private final AtomicBoolean reported = new AtomicBoolean();

        Prober(Path dir) {
            this.dir = dir;
        }

        int run(long secs, Path stop) throws InterruptedException {
            // `docker stop` sends SIGTERM: the counts still get out. (rm -f is
            // SIGKILL, which nothing survives - the suite waits for the stop file.)
            Runtime.getRuntime().addShutdownHook(new Thread(this::report));
            System.out.println("PROBING " + dir);
            System.out.flush();
            long deadline = System.nanoTime() + secs * 1_000_000_000L;
            String lastError = null;
            while (!due(deadline, stop)) {
                rounds++;
                for (Path p : list()) {
                    String name = p.getFileName().toString();
                    synchronized (this) {
                        seen.add(name);
                    }
                    // No CREATE: a file that is gone is simply not there, and
                    // this never makes a lock file of its own for Maven to find.
                    try (FileChannel ch = FileChannel.open(p, StandardOpenOption.READ, StandardOpenOption.WRITE)) {
                        FileLock l = ch.tryLock(0, 1, false);
                        if (l == null) {
                            contended++;
                            synchronized (this) {
                                contendedFiles.add(name);
                            }
                        } else {
                            free++;
                            l.release();
                        }
                    } catch (NoSuchFileException e) {
                        vanished++;
                    } catch (IOException | OverlappingFileLockException e) {
                        errors++;
                        lastError = name + ": " + e;
                    }
                }
                Thread.sleep(10);
            }
            if (lastError != null) {
                System.out.println("PROBE last error: " + lastError);
            }
            report();
            return 0;
        }

        private List<Path> list() {
            List<Path> out = new ArrayList<>();
            if (!Files.isDirectory(dir)) {
                return out;   // the build has not created it yet
            }
            try (DirectoryStream<Path> ds = Files.newDirectoryStream(dir, "*.lock")) {
                for (Path p : ds) {
                    out.add(p);
                }
            } catch (IOException e) {
                errors++;
            }
            return out;
        }

        private void report() {
            if (!reported.compareAndSet(false, true)) {
                return;
            }
            int nSeen;
            int nContended;
            synchronized (this) {
                nSeen = seen.size();
                nContended = contendedFiles.size();
            }
            System.out.println("PROBE rounds=" + rounds + " free=" + free + " vanished=" + vanished
                    + " errors=" + errors + " contended_files=" + nContended);
            System.out.println("CONTENDED=" + contended + " SEEN=" + nSeen);
            System.out.flush();
        }
    }
}
