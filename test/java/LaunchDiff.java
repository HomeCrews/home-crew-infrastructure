/*
 * Suite E (parity): compares two captures of test/container/capture-launch.sh -
 * the application as spring-boot:run launched it (OLD, the baseline
 * dev-reload.sh) and as dev-reload.sh launches it now with plain java (NEW) -
 * and prints one HCRESULT line per property of the launch.
 *
 *     java LaunchDiff.java <old> <new> <whitelist> <volatile-file> <service>
 *     java LaunchDiff.java --learn <newA> <newB> [<newA> <newB> ...]
 *
 * Run inside homecrew-dev-runtime:jdk25 with the Maven volume the captures
 * came from mounted at /root/.m2: the classpath check has to open the jars the
 * two JVMs were given, by the paths they were given, to read their manifests.
 * Single file, JDK only, no dependencies - `java File.java` compiles it in
 * memory, so nothing has to be built or downloaded first.
 *
 * WHAT "THE SAME LAUNCH" MEANS here, check by check. The reference is what
 * spring-boot:run 4.1.1 forks (RunMojo / AbstractRunMojo / RunProcess):
 *
 *   jvm-args   exact. -XX:TieredStopAtLevel=1 first, then jvmArguments (the
 *              jdwp agent). Any other flag, or the two the other way round,
 *              is a different JVM.
 *   main       exact, and no application arguments.
 *   classpath  exact, as an ordered list, after one allowed difference:
 *              spring-boot:run drops jars whose manifest Spring-Boot-Jar-Type
 *              is dependencies-starter, annotation-processor or
 *              development-tool (JarTypeFilter); dependency:build-classpath
 *              keeps them. Only NEW-only jars of those types are dropped. An
 *              ORDER difference fails - classpath order decides which of two
 *              duplicate classes wins, so it is not cosmetic.
 *   sysprops   equal, minus the volatile set and the whitelist.
 *   env        equal, minus the volatile set and the whitelist.
 *   cwd        /app in both - config-server imports optional:file:.env from
 *              the working directory.
 *   exe        the same binary (compared through /proc/<pid>/exe: argv[0]
 *              may legitimately be spelled differently).
 *   streams    stderr is stdout in both (RunProcess: redirectErrorStream).
 *   nomaven    OLD had a Maven JVM parked beside the application; NEW has none.
 *   jdwp       the APPLICATION pid owns the LISTEN socket on 5005.
 *   sigign     reported, not judged: both launches are stopped with SIGTERM.
 *
 * THE VOLATILE SET is learned, not guessed: --learn prints every key that
 * differs between two NEW launches of the same service. Whatever changes
 * between two identical launches (a pid, a temp directory) cannot be
 * evidence that the launch changed. The exception is what the launch itself
 * decides (NEVER_VOLATILE: user.dir, the classpath, SPRING_* and DEV_*, ...):
 * two NEW launches that disagree there are reported, never learned.
 *
 * Exit status: 0 = no FAIL, 1 = at least one FAIL, 2 = usage or input error
 * (a malformed whitelist is an input error, not a verdict).
 */

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.TreeSet;
import java.util.jar.JarFile;
import java.util.jar.Manifest;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class LaunchDiff {

    static final String LAUNCHER = "org.codehaus.plexus.classworlds.launcher.Launcher";
    static final String APP_DIR = "/app";
    static final String CLASSES = "/app/target/classes";
    static final String TIERED = "-XX:TieredStopAtLevel=1";
    static final String JDWP = "-agentlib:jdwp=";
    static final Set<String> FILTERED_JAR_TYPES =
            Set.of("dependencies-starter", "annotation-processor", "development-tool");

    // A Maven or resolver property on the APPLICATION's command line means a
    // build setting leaked into the app JVM (JAVA_TOOL_OPTIONS, JDK_JAVA_OPTIONS).
    // Both launches would show it, so "equal" alone would not catch it.
    static final Pattern BUILD_PROPERTY =
            Pattern.compile("(aether|maven|mvnd|classworlds|library\\.jansi)(\\..*)?");

    // What the launch decides, and so what two NEW launches of one service
    // must agree on. If they do not, NEW is not deterministic - a parity bug
    // in itself, never noise: --learn reports these instead of learning them,
    // and a volatile file that lists one anyway excuses nothing for it.
    static final Set<String> NEVER_VOLATILE = Set.of(
            "prop user.dir", "prop java.home", "prop sun.java.command", "prop java.class.path",
            "prop file.encoding", "prop native.encoding", "env JAVA_TOOL_OPTIONS");
    static final List<String> NEVER_VOLATILE_ENV_PREFIXES = List.of("SPRING_", "DEV_");

    static boolean neverVolatile(String kindKey) {
        if (NEVER_VOLATILE.contains(kindKey)) return true;
        if (!kindKey.startsWith("env ")) return false;
        for (String p : NEVER_VOLATILE_ENV_PREFIXES) if (kindKey.startsWith("env " + p)) return true;
        return false;
    }

    static final Pattern SECTION = Pattern.compile("^==([a-z0-9_]+)==$");
    static final Pattern PID_LINE = Pattern.compile("^[0-9]+:$");
    static final String[] SIGNALS = {
        "", "HUP", "INT", "QUIT", "ILL", "TRAP", "ABRT", "BUS", "FPE", "KILL", "USR1", "SEGV",
        "USR2", "PIPE", "ALRM", "TERM", "STKFLT", "CHLD", "CONT", "STOP", "TSTP", "TTIN", "TTOU",
        "URG", "XCPU", "XFSZ", "VTALRM", "PROF", "WINCH", "IO", "PWR", "SYS"
    };

    public static void main(String[] args) {
        int rc;
        try {
            if (args.length > 0 && args[0].equals("--learn")) {
                rc = learn(Arrays.copyOfRange(args, 1, args.length));
            } else if (args.length == 5) {
                rc = new LaunchDiff(args).run();
            } else {
                System.err.println("usage: java LaunchDiff.java <old> <new> <whitelist> <volatile-file> <service>");
                System.err.println("       java LaunchDiff.java --learn <newA> <newB> [<newA> <newB> ...]");
                rc = 2;
            }
        } catch (InputError e) {
            System.err.println("LaunchDiff: " + e.getMessage());
            rc = 2;
        }
        System.exit(rc);
    }

    static final class InputError extends RuntimeException {
        private static final long serialVersionUID = 1L;

        InputError(String m) { super(m); }
    }

    // -----------------------------------------------------------------------
    // Inputs
    // -----------------------------------------------------------------------

    /** One capture-launch.sh output: ==name== sections of lines. */
    static final class Capture {
        final String label;
        final Path path;
        final Map<String, List<String>> sections = new LinkedHashMap<>();

        Capture(String label, Path path) {
            this.label = label;
            this.path = path;
            String text;
            try {
                // Decoded leniently: a stray byte in an environment value must
                // not turn the whole comparison into an exception.
                text = new String(Files.readAllBytes(path), StandardCharsets.UTF_8);
            } catch (IOException e) {
                throw new InputError("cannot read " + label + " capture " + path + ": " + e.getMessage());
            }
            String cur = null;
            for (String raw : text.split("\n", -1)) {
                String l = raw.endsWith("\r") ? raw.substring(0, raw.length() - 1) : raw;
                Matcher m = SECTION.matcher(l);
                if (m.matches()) {
                    cur = m.group(1);
                    sections.putIfAbsent(cur, new ArrayList<>());
                } else if (cur != null) {
                    sections.get(cur).add(l);
                }
            }
            // A trailing newline leaves one empty line on the last section.
            for (List<String> v : sections.values()) {
                while (!v.isEmpty() && v.get(v.size() - 1).isEmpty()) v.remove(v.size() - 1);
            }
        }

        boolean has(String s) { return sections.containsKey(s); }

        List<String> get(String s) { return sections.getOrDefault(s, List.of()); }

        String first(String s) {
            for (String l : get(s)) if (!l.isBlank()) return l.trim();
            return "";
        }

        /** The capture script's own "!! ..." note if this section failed, else null. */
        String failure(String s) {
            if (!has(s)) return "section ==" + s + "== is missing from the " + label + " capture";
            for (String l : get(s)) if (l.startsWith("!! ")) return label + ": " + l.substring(3);
            return null;
        }
    }

    record CommandLine(String jvmArgs, String javaCommand, List<String> classPath) {}

    static CommandLine commandLine(Capture c) {
        String jvm = null, cmd = null, cp = null;
        for (String l : c.get("vm_command_line")) {
            if (l.startsWith("jvm_args:")) jvm = l.substring("jvm_args:".length()).trim();
            else if (l.startsWith("java_command:")) cmd = l.substring("java_command:".length()).trim();
            else if (l.startsWith("java_class_path (initial):"))
                cp = l.substring("java_class_path (initial):".length()).trim();
        }
        if (cmd == null) return null;
        // HotSpot prints no jvm_args line at all when there are none.
        if (jvm == null) jvm = "";
        List<String> entries = new ArrayList<>();
        if (cp != null && !cp.isEmpty() && !cp.equals("<not set>")) {
            entries.addAll(Arrays.asList(cp.split(":", -1)));
        }
        return new CommandLine(jvm, cmd, entries);
    }

    static List<String> tokens(String s) {
        List<String> t = new ArrayList<>();
        for (String x : s.trim().split("\\s+")) if (!x.isEmpty()) t.add(x);
        return t;
    }

    /**
     * VM.system_properties is Properties.store output: key=value, keys escaped.
     * store escapes every space in a key and always writes the '=', so a line
     * with an unescaped blank before any '=', or with no '=' at all, is not a
     * property: it is jcmd's or the JVM's own chatter ("Picked up
     * JAVA_TOOL_OPTIONS:", a VM warning) that the capture's 2>&1 mixed in.
     */
    static Map<String, String> properties(Capture c) {
        Map<String, String> m = new TreeMap<>();
        for (String l : c.get("system_properties")) {
            if (l.isEmpty() || l.startsWith("#") || l.startsWith("!! ") || PID_LINE.matcher(l).matches()) continue;
            StringBuilder key = new StringBuilder();
            boolean separated = false, blank = false;
            int i = 0;
            for (; i < l.length(); i++) {
                char ch = l.charAt(i);
                if (ch == '\\' && i + 1 < l.length()) {
                    char nx = l.charAt(++i);
                    if (nx == 'u' && i + 4 < l.length()) {
                        try {
                            key.append((char) Integer.parseInt(l.substring(i + 1, i + 5), 16));
                            i += 4;
                            continue;
                        } catch (NumberFormatException e) {
                            // not an escape after all - keep it literally
                        }
                    }
                    key.append(nx);
                } else if (ch == '=') {
                    separated = true;
                    break;
                } else if (ch == ' ' || ch == '\t') {
                    blank = true;
                    break;
                } else {
                    key.append(ch);
                }
            }
            if (!separated || blank) continue;
            m.put(key.toString(), l.substring(i + 1));
        }
        return m;
    }

    /** /proc/<pid>/environ, one KEY=VALUE per line. */
    static Map<String, String> environment(Capture c) {
        Map<String, String> m = new TreeMap<>();
        for (String l : c.get("environ")) {
            if (l.isEmpty() || l.startsWith("!! ")) continue;
            int i = l.indexOf('=');
            if (i < 0) m.put(l, "");
            else m.put(l.substring(0, i), l.substring(i + 1));
        }
        return m;
    }

    record Rule(String kind, String key, String allowed, String reason) {}

    static final Set<String> KINDS = Set.of("env", "prop");
    static final Set<String> ALLOWED = Set.of("any", "value", "old-only", "new-only");

    static Map<String, Rule> readWhitelist(Path p) {
        Map<String, Rule> rules = new LinkedHashMap<>();
        List<String> lines;
        try {
            lines = Files.readAllLines(p, StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new InputError("cannot read whitelist " + p + ": " + e.getMessage());
        }
        int n = 0;
        for (String raw : lines) {
            n++;
            String l = raw.strip();
            if (l.isEmpty() || l.startsWith("#")) continue;
            String[] f = l.split("\\s+", 4);
            String where = p.getFileName() + ":" + n + ": ";
            if (f.length < 4 || f[3].isBlank())
                throw new InputError(where + "expected '<kind> <key> <allowed> <reason>' - every entry needs its reason");
            if (!KINDS.contains(f[0])) throw new InputError(where + "kind must be env or prop, not '" + f[0] + "'");
            if (!ALLOWED.contains(f[2]))
                throw new InputError(where + "allowed must be one of " + new TreeSet<>(ALLOWED) + ", not '" + f[2] + "'");
            if (rules.put(f[0] + " " + f[1], new Rule(f[0], f[1], f[2], f[3].strip())) != null)
                throw new InputError(where + f[0] + " " + f[1] + " is listed twice");
        }
        return rules;
    }

    /** "prop <key>" / "env <key>" lines; # starts a comment. A missing file is an empty set. */
    static Set<String> readVolatile(Path p, List<String> notes) {
        Set<String> s = new TreeSet<>();
        if (!Files.isRegularFile(p)) {
            notes.add("no volatile set at " + p + " - every difference counts");
            return s;
        }
        try {
            for (String raw : Files.readAllLines(p, StandardCharsets.UTF_8)) {
                int hash = raw.indexOf('#');
                String l = (hash >= 0 ? raw.substring(0, hash) : raw).strip();
                if (l.isEmpty()) continue;
                String[] f = l.split("\\s+");
                if (f.length != 2 || !KINDS.contains(f[0]))
                    throw new InputError(p + ": expected '<env|prop> <key>', got '" + l + "'");
                s.add(f[0] + " " + f[1]);
            }
        } catch (IOException e) {
            throw new InputError("cannot read volatile set " + p + ": " + e.getMessage());
        }
        return s;
    }

    static String jarType(String path) {
        File f = new File(path);
        if (f.isDirectory()) return "<directory>";
        if (!f.isFile()) return "<missing>";
        try (JarFile j = new JarFile(f, false)) {
            Manifest mf = j.getManifest();
            if (mf == null) return "<no manifest>";
            String t = mf.getMainAttributes().getValue("Spring-Boot-Jar-Type");
            return t == null ? "<none>" : t.strip();
        } catch (IOException e) {
            return "<unreadable: " + e.getMessage() + ">";
        }
    }

    // -----------------------------------------------------------------------
    // The comparison
    // -----------------------------------------------------------------------

    final Capture oldC, newC;
    final Map<String, Rule> whitelist;
    final Set<String> volatileKeys;
    final String service;
    final List<String> notes = new ArrayList<>();
    boolean failed;

    LaunchDiff(String[] a) {
        oldC = new Capture("OLD", Path.of(a[0]));
        newC = new Capture("NEW", Path.of(a[1]));
        whitelist = readWhitelist(Path.of(a[2]));
        volatileKeys = readVolatile(Path.of(a[3]), notes);
        service = a[4];
    }

    int run() {
        System.out.println("LaunchDiff " + service + ": OLD=" + oldC.path + " NEW=" + newC.path);
        System.out.println("  whitelist: " + whitelist.size() + " rules; volatile set: " + volatileKeys);
        for (String n : notes) System.out.println("  note: " + n);
        checkJvmArgs();
        checkMain();
        checkClasspath();
        checkMaps("sysprops", "prop", properties(oldC), properties(newC), "system_properties");
        checkMaps("env", "env", environment(oldC), environment(newC), "environ");
        checkCwd();
        checkExe();
        checkStreams();
        checkNoMaven();
        checkJdwp();
        checkSigIgn();
        return failed ? 1 : 0;
    }

    /** Detail lines for the evidence file, then the verdict line itself. */
    void result(String check, String status, String message, List<String> details) {
        String id = "E-" + service + "-" + check;
        System.out.println("-- " + id);
        for (String d : details) System.out.println("   " + d);
        if (status.equals("FAIL")) failed = true;
        System.out.println("HCRESULT\t" + id + "\t" + status + "\t" + message.replaceAll("[\t\r\n]", " "));
    }

    void result(String check, String status, String message) { result(check, status, message, List.of()); }

    /** A check that cannot run because a capture section failed. */
    boolean missing(String check, String... sections) {
        List<String> why = new ArrayList<>();
        for (String s : sections) {
            String a = oldC.failure(s), b = newC.failure(s);
            if (a != null) why.add(a);
            if (b != null) why.add(b);
        }
        if (why.isEmpty()) return false;
        result(check, "FAIL", "not compared - " + String.join("; ", why));
        return true;
    }

    void checkJvmArgs() {
        if (missing("jvm-args", "vm_command_line", "flags")) return;
        CommandLine o = commandLine(oldC), n = commandLine(newC);
        if (o == null || n == null) {
            result("jvm-args", "FAIL", "no java_command in the " + (o == null ? "OLD" : "NEW") + " VM.command_line output");
            return;
        }
        List<String> problems = new ArrayList<>(), details = new ArrayList<>();
        details.add("OLD jvm_args: " + o.jvmArgs());
        details.add("NEW jvm_args: " + n.jvmArgs());
        if (!o.jvmArgs().equals(n.jvmArgs()))
            problems.add("jvm_args differ: OLD '" + o.jvmArgs() + "', NEW '" + n.jvmArgs() + "'");
        List<String> nt = tokens(n.jvmArgs());
        int tiered = nt.indexOf(TIERED);
        int jdwp = -1;
        for (int i = 0; i < nt.size(); i++) if (nt.get(i).startsWith(JDWP)) { jdwp = i; break; }
        if (tiered < 0)
            problems.add("NEW has no " + TIERED + ", which spring-boot:run always puts first (is DEV_OPTIMIZED_LAUNCH=false?)");
        if (jdwp < 0) problems.add("NEW has no " + JDWP + "... agent - DEV_JVM_ARGS did not reach the JVM");
        if (tiered >= 0 && jdwp >= 0 && tiered > jdwp)
            problems.add(TIERED + " comes after the jdwp agent; spring-boot:run puts it first (addFirst)");

        // VM.flags: what the JVM made of its arguments, ergonomics included.
        // The two run under the same limits, so these should agree too - but
        // a difference here that jvm_args does not explain is a caveat, not
        // a different launch.
        // jcmd puts a "<pid>:" line above the flags, hence all lines and -XX: only.
        Set<String> of = new TreeSet<>(tokens(String.join(" ", oldC.get("flags"))));
        Set<String> nf = new TreeSet<>(tokens(String.join(" ", newC.get("flags"))));
        of.removeIf(t -> !t.startsWith("-XX:"));
        nf.removeIf(t -> !t.startsWith("-XX:"));
        if (tiered >= 0 && !nf.contains(TIERED))
            problems.add("VM.flags of NEW do not show " + TIERED);
        Set<String> onlyO = new TreeSet<>(of), onlyN = new TreeSet<>(nf);
        onlyO.removeAll(nf);
        onlyN.removeAll(of);
        if (!onlyO.isEmpty()) details.add("VM.flags only in OLD: " + onlyO);
        if (!onlyN.isEmpty()) details.add("VM.flags only in NEW: " + onlyN);

        if (!problems.isEmpty()) {
            result("jvm-args", "FAIL", String.join("; ", problems), details);
        } else if (!onlyO.isEmpty() || !onlyN.isEmpty()) {
            result("jvm-args", "WARN", "jvm_args identical ('" + n.jvmArgs() + "'), but VM.flags differ: OLD only "
                    + cap(onlyO, 4) + ", NEW only " + cap(onlyN, 4), details);
        } else {
            result("jvm-args", "PASS", "identical: '" + n.jvmArgs() + "' - " + TIERED
                    + " first, then the jdwp agent; VM.flags identical", details);
        }
    }

    void checkMain() {
        if (missing("main", "vm_command_line")) return;
        CommandLine o = commandLine(oldC), n = commandLine(newC);
        if (o == null || n == null) {
            result("main", "FAIL", "no java_command in the " + (o == null ? "OLD" : "NEW") + " VM.command_line output");
            return;
        }
        String expected = newC.first("main");
        List<String> problems = new ArrayList<>();
        if (!o.javaCommand().equals(n.javaCommand()))
            problems.add("java_command differs: OLD '" + o.javaCommand() + "', NEW '" + n.javaCommand() + "'");
        if (!expected.isEmpty() && !n.javaCommand().equals(expected))
            problems.add("NEW java_command is '" + n.javaCommand() + "', expected exactly '" + expected + "' with no arguments");
        if (tokens(n.javaCommand()).size() > 1)
            problems.add("NEW passes application arguments: '" + n.javaCommand() + "'");
        if (problems.isEmpty()) {
            result("main", "PASS", "java_command '" + n.javaCommand() + "' in both, no application arguments");
        } else {
            result("main", "FAIL", String.join("; ", problems));
        }
    }

    void checkClasspath() {
        if (missing("classpath", "vm_command_line")) return;
        CommandLine oc = commandLine(oldC), nc = commandLine(newC);
        if (oc == null || nc == null) {
            result("classpath", "FAIL", "no VM.command_line in the " + (oc == null ? "OLD" : "NEW") + " capture");
            return;
        }
        List<String> o = oc.classPath(), n = nc.classPath();
        List<String> problems = new ArrayList<>(), details = new ArrayList<>();

        for (String e : new java.util.LinkedHashSet<>(concat(o, n))) {
            if (e.endsWith("/test-classes") || e.contains("/test-classes/"))
                problems.add("test classes are on a classpath: " + e);
        }
        if (n.isEmpty()) problems.add("NEW has an empty classpath");
        else if (!n.get(0).equals(CLASSES))
            problems.add("NEW classpath starts with '" + n.get(0) + "', not " + CLASSES + " (absolute, as the plugin passes it)");
        if (n.contains("")) problems.add("NEW classpath has an empty entry, which puts the working directory on it");

        // The one allowed difference: jars spring-boot:run's JarTypeFilter
        // removes. Only those that NEW has and OLD does not - a filtered type
        // on BOTH sides would mean the reference itself was not filtered.
        Set<String> inOld = new HashSet<>(o);
        List<String> kept = new ArrayList<>();
        List<String> dropped = new ArrayList<>();
        Map<String, String> extraTypes = new LinkedHashMap<>();
        for (String e : n) {
            if (!inOld.contains(e)) {
                String t = jarType(e);
                if (FILTERED_JAR_TYPES.contains(t)) {
                    dropped.add(fileName(e) + " (" + t + ")");
                    continue;
                }
                extraTypes.put(e, t);
            }
            kept.add(e);
        }
        details.add("OLD: " + o.size() + " entries; NEW: " + n.size() + " entries, " + dropped.size() + " dropped as spring-boot:run drops them");
        for (String d : dropped) details.add("dropped from NEW: " + d);

        if (!kept.equals(o)) {
            Set<String> inKept = new HashSet<>(kept);
            List<String> oldOnly = new ArrayList<>(), newOnly = new ArrayList<>();
            for (String e : o) if (!inKept.contains(e)) oldOnly.add(e);
            for (String e : kept) if (!inOld.contains(e)) newOnly.add(e);
            for (String e : oldOnly) details.add("only in OLD: " + e);
            for (String e : newOnly) details.add("only in NEW: " + e + " (Spring-Boot-Jar-Type " + extraTypes.getOrDefault(e, "?") + ")");
            if (oldOnly.isEmpty() && newOnly.isEmpty()) {
                int i = 0;
                while (i < Math.min(o.size(), kept.size()) && o.get(i).equals(kept.get(i))) i++;
                String a = i < o.size() ? fileName(o.get(i)) : "<end>", b = i < kept.size() ? fileName(kept.get(i)) : "<end>";
                problems.add("the same entries in a different order (or duplicated): first difference at #" + (i + 1)
                        + ", OLD " + a + ", NEW " + b + " - class lookup order is not cosmetic");
            } else {
                if (!oldOnly.isEmpty())
                    problems.add(oldOnly.size() + " entr" + (oldOnly.size() == 1 ? "y" : "ies") + " only in OLD (provided/system scope?): "
                            + cap(names(oldOnly), 3));
                if (!newOnly.isEmpty())
                    problems.add(newOnly.size() + " entr" + (newOnly.size() == 1 ? "y" : "ies") + " only in NEW that spring-boot:run would keep: "
                            + cap(names(newOnly), 3));
            }
        }

        if (problems.isEmpty()) {
            result("classpath", "PASS", o.size() + " entries, identical and in the same order, after dropping " + dropped.size()
                    + " NEW-only jar(s) spring-boot:run filters out by Spring-Boot-Jar-Type" + (dropped.isEmpty() ? "" : ": " + cap(dropped, 3)), details);
        } else {
            result("classpath", "FAIL", String.join("; ", problems), details);
        }
    }

    void checkMaps(String check, String kind, Map<String, String> o, Map<String, String> n, String section) {
        if (missing(check, section)) return;
        List<String> problems = new ArrayList<>(), allowed = new ArrayList<>(), details = new ArrayList<>();
        int equal = 0;
        TreeSet<String> keys = new TreeSet<>(o.keySet());
        keys.addAll(n.keySet());
        for (String k : keys) {
            boolean inO = o.containsKey(k), inN = n.containsKey(k);
            if (inO && inN && o.get(k).equals(n.get(k))) {
                equal++;
                continue;
            }
            String what = describe(k, o, n);
            String kk = kind + " " + k;
            boolean learned = volatileKeys.contains(kk);
            if (learned && !neverVolatile(kk)) {
                allowed.add(k);
                details.add("volatile: " + what);
                continue;
            }
            Rule r = whitelist.get(kk);
            if (r != null && permits(r.allowed(), inO, inN)) {
                allowed.add(k);
                details.add("whitelisted (" + r.allowed() + "): " + what + " - " + r.reason());
                continue;
            }
            problems.add(k);
            details.add("DIFFERS: " + what + (r != null ? " - whitelisted only as " + r.allowed() : "")
                    + (learned ? " - listed as volatile, but the launch decides it, so NEW must be deterministic in it" : ""));
        }
        // Equal on both sides is not enough for build settings: see BUILD_PROPERTY.
        List<String> build = new ArrayList<>();
        if (kind.equals("prop")) {
            for (String k : n.keySet()) {
                if (BUILD_PROPERTY.matcher(k).matches() && !whitelist.containsKey("prop " + k)) {
                    build.add(k);
                    details.add("BUILD PROPERTY in NEW: " + k + "=" + clip(n.get(k)));
                }
            }
        }
        String one = kind.equals("prop") ? "system property" : "environment variable";
        String many = kind.equals("prop") ? "system properties" : "environment variables";
        List<String> msg = new ArrayList<>();
        if (!problems.isEmpty())
            msg.add(problems.size() + " " + (problems.size() == 1 ? one + " differs" : many + " differ") + ": " + cap(problems, 8));
        if (!build.isEmpty())
            msg.add("Maven/resolver properties inside the application JVM: " + cap(build, 5));
        String counts = equal + " " + (equal == 1 ? one : many) + " identical, " + allowed.size() + " allowed to differ";
        if (msg.isEmpty()) {
            result(check, "PASS", counts + (allowed.isEmpty() ? "" : " (" + cap(allowed, 8) + ")"), details);
        } else {
            result(check, "FAIL", String.join("; ", msg) + " (" + counts + ")", details);
        }
    }

    static boolean permits(String allowed, boolean inO, boolean inN) {
        return switch (allowed) {
            case "any" -> true;
            case "value" -> inO && inN;
            case "old-only" -> inO && !inN;
            case "new-only" -> !inO && inN;
            default -> false;
        };
    }

    static String describe(String k, Map<String, String> o, Map<String, String> n) {
        if (!n.containsKey(k)) return k + " only in OLD ('" + clip(o.get(k)) + "')";
        if (!o.containsKey(k)) return k + " only in NEW ('" + clip(n.get(k)) + "')";
        return k + ": OLD '" + clip(o.get(k)) + "', NEW '" + clip(n.get(k)) + "'";
    }

    void checkCwd() {
        if (missing("cwd", "cwd")) return;
        String o = oldC.first("cwd"), n = newC.first("cwd");
        if (o.equals(APP_DIR) && n.equals(APP_DIR)) result("cwd", "PASS", APP_DIR + " in both");
        else result("cwd", "FAIL", "expected " + APP_DIR + " in both: OLD '" + o + "', NEW '" + n + "'");
    }

    void checkExe() {
        if (missing("exe", "exe")) return;
        String o = oldC.first("exe"), n = newC.first("exe");
        String argv0 = "argv[0] OLD '" + oldC.first("cmdline") + "', NEW '" + newC.first("cmdline") + "'";
        if (!o.isEmpty() && o.equals(n)) result("exe", "PASS", "the same binary, " + n + " (" + argv0 + ")");
        else result("exe", "FAIL", "different binaries: OLD '" + o + "', NEW '" + n + "' (" + argv0 + ")");
    }

    void checkStreams() {
        if (missing("streams", "fd1", "fd2")) return;
        List<String> problems = new ArrayList<>();
        boolean tty = false;
        for (Capture c : List.of(oldC, newC)) {
            String a = c.first("fd1"), b = c.first("fd2");
            if (a.isEmpty() || !a.equals(b)) problems.add(c.label + " stdout '" + a + "' is not its stderr '" + b + "'");
            if (a.startsWith("/dev/pts/") || a.startsWith("/dev/tty")) tty = true;
        }
        String shape = "OLD " + oldC.first("fd1") + ", NEW " + newC.first("fd1");
        if (!problems.isEmpty()) {
            result("streams", "FAIL", String.join("; ", problems) + " - spring-boot:run merged stderr into stdout");
        } else if (tty) {
            // With a terminal both descriptors are the same tty whatever the
            // launch did, so equality proves nothing: compose run needs -T.
            result("streams", "WARN", "fd 1 = fd 2 in both, but on a TTY, where that holds regardless (" + shape + ")");
        } else {
            result("streams", "PASS", "stderr is stdout in both, as spring-boot:run's redirectErrorStream made it (" + shape + ")");
        }
    }

    record Jvm(String pid, String main) {}

    static List<Jvm> jvms(Capture c) {
        List<Jvm> r = new ArrayList<>();
        for (String l : c.get("jcmd_l")) {
            List<String> t = tokens(l);
            if (t.size() >= 2 && t.get(0).chars().allMatch(Character::isDigit)) r.add(new Jvm(t.get(0), t.get(1)));
        }
        return r;
    }

    void checkNoMaven() {
        if (missing("nomaven", "jcmd_l", "ppid")) return;
        List<String> problems = new ArrayList<>();
        boolean oldHas = jvms(oldC).stream().anyMatch(j -> j.main().equals(LAUNCHER));
        List<Jvm> newJvms = jvms(newC);
        boolean newHas = newJvms.stream().anyMatch(j -> j.main().equals(LAUNCHER));
        String app = newC.first("main");
        List<String> others = new ArrayList<>();
        for (Jvm j : newJvms) {
            if (!j.main().equals(app) && !j.main().endsWith("sun.tools.jcmd.JCmd")) others.add(j.main());
        }
        List<String> po = tokens(oldC.first("ppid")), pn = tokens(newC.first("ppid"));
        String oldParent = po.size() >= 2 ? po.get(1) : "?", newParent = pn.size() >= 2 ? pn.get(1) : "?";
        if (newHas) problems.add("NEW still has a Maven launcher JVM (" + LAUNCHER + ")");
        if (!oldHas) problems.add("OLD had no Maven launcher JVM, so it was not a spring-boot:run launch - the comparison has no reference");
        if (newParent.equals("java")) problems.add("NEW's parent process is a JVM, not the dev-reload.sh shell");
        String facts = "OLD parent " + oldParent + " (pid " + (po.isEmpty() ? "?" : po.get(0)) + "), NEW parent " + newParent
                + " (pid " + (pn.isEmpty() ? "?" : pn.get(0)) + ")" + (others.isEmpty() ? "" : "; other JVMs in NEW: " + others);
        if (problems.isEmpty()) {
            result("nomaven", "PASS", "no Maven JVM beside the application any more; " + facts);
        } else {
            result("nomaven", "FAIL", String.join("; ", problems) + "; " + facts);
        }
    }

    record Listen(String proto, String addr, boolean owned) {}

    static List<Listen> listens(Capture c) {
        List<Listen> r = new ArrayList<>();
        for (String l : c.get("jdwp")) {
            List<String> t = tokens(l);
            if (t.size() >= 5 && t.get(0).equals("listen")) r.add(new Listen(t.get(1), t.get(2), t.get(4).equals("owned=yes")));
        }
        return r;
    }

    void checkJdwp() {
        if (missing("jdwp", "jdwp")) return;
        List<Listen> n = listens(newC), o = listens(oldC);
        boolean newOwned = n.stream().anyMatch(Listen::owned), oldOwned = o.stream().anyMatch(Listen::owned);
        String oldFact = "OLD: " + (oldOwned ? "the application owned it too" : o.isEmpty() ? "nothing listened on 5005" : "a socket on 5005 not owned by the application");
        List<String> details = new ArrayList<>();
        for (String l : newC.get("jdwp")) details.add("NEW " + l);
        for (String l : oldC.get("jdwp")) details.add("OLD " + l);
        if (newOwned) {
            Listen l = n.stream().filter(Listen::owned).findFirst().get();
            result("jdwp", "PASS", "the NEW application pid owns the LISTEN socket on container port 5005 (" + l.proto() + " " + l.addr() + "); " + oldFact, details);
        } else if (n.isEmpty()) {
            result("jdwp", "FAIL", "nothing listens on container port 5005 in NEW; " + oldFact, details);
        } else {
            result("jdwp", "FAIL", "port 5005 listens in NEW, but the socket is not the application's; " + oldFact, details);
        }
    }

    static long sigIgn(Capture c) {
        for (String l : c.get("sigign")) {
            List<String> t = tokens(l);
            if (t.size() == 2 && t.get(0).equals("SigIgn:")) {
                try {
                    return Long.parseUnsignedLong(t.get(1), 16);
                } catch (NumberFormatException e) {
                    return -1;
                }
            }
        }
        return -1;
    }

    static String signals(long mask) {
        List<String> s = new ArrayList<>();
        for (int i = 1; i <= 64; i++) {
            if ((mask & (1L << (i - 1))) != 0) s.add(i < SIGNALS.length ? SIGNALS[i] : "SIG" + i);
        }
        return s.isEmpty() ? "none" : String.join(",", s);
    }

    void checkSigIgn() {
        long o = sigIgn(oldC), n = sigIgn(newC);
        if (o < 0 || n < 0) {
            result("sigign", "INFO", "SigIgn not captured (OLD " + (o < 0 ? "missing" : signals(o)) + ", NEW " + (n < 0 ? "missing" : signals(n)) + ")");
        } else if (o == n) {
            result("sigign", "PASS", "the same ignored signals in both: " + signals(n));
        } else {
            result("sigign", "INFO", "ignored signals differ: OLD " + signals(o) + ", NEW " + signals(n)
                    + " - both launches are stopped with SIGTERM, which neither ignores unless listed");
        }
    }

    // -----------------------------------------------------------------------
    // --learn: the volatile set
    // -----------------------------------------------------------------------

    static int learn(String[] files) {
        if (files.length == 0 || files.length % 2 != 0) {
            System.err.println("usage: java LaunchDiff.java --learn <newA> <newB> [<newA> <newB> ...]");
            return 2;
        }
        Map<String, TreeSet<String>> found = new TreeMap<>();
        List<String> from = new ArrayList<>(), skipped = new ArrayList<>();
        pairs:
        for (int i = 0; i < files.length; i += 2) {
            Capture a = new Capture("A", Path.of(files[i])), b = new Capture("B", Path.of(files[i + 1]));
            String name = fileName(files[i]).replaceFirst("\\.[^.]*$", "");
            // A pair with a failed section is left out, not the whole set: the
            // other service's pair is still good evidence.
            for (String section : new String[] {"system_properties", "environ"}) {
                String why = a.failure(section) != null ? a.failure(section) : b.failure(section);
                if (why != null) {
                    skipped.add(name + ": " + why);
                    continue pairs;
                }
            }
            from.add(name + " (" + fileName(files[i]) + " vs " + fileName(files[i + 1]) + ")");
            for (String[] kind : new String[][] {{"prop", "system_properties"}, {"env", "environ"}}) {
                Map<String, String> x = kind[0].equals("prop") ? properties(a) : environment(a);
                Map<String, String> y = kind[0].equals("prop") ? properties(b) : environment(b);
                TreeSet<String> keys = new TreeSet<>(x.keySet());
                keys.addAll(y.keySet());
                for (String k : keys) {
                    if (!java.util.Objects.equals(x.get(k), y.get(k)))
                        found.computeIfAbsent(kind[0] + " " + k, z -> new TreeSet<>()).add(name);
                }
            }
        }
        System.out.println("# Volatile keys for suite E: values that differed between two NEW launches");
        System.out.println("# of the same service, so that a difference in them says nothing about how");
        System.out.println("# the application was launched. Learned from: " + String.join(", ", from));
        for (String s : skipped) System.out.println("# skipped " + s);
        // Only a comment for what must not, or cannot, be read back as a key:
        // readVolatile splits on blanks and cuts at '#'.
        for (Map.Entry<String, TreeSet<String>> e : found.entrySet()) {
            String k = e.getKey(), svcs = String.join(", ", e.getValue());
            if (neverVolatile(k)) System.out.println("# NEVER-VOLATILE " + k + "    (" + svcs + ")");
            else if (k.substring(k.indexOf(' ') + 1).matches("(?s).*[\\s#].*"))
                System.out.println("# unusable as a key, a blank or '#' in it: " + k + "    (" + svcs + ")");
            else System.out.println(k + "    # " + svcs);
        }
        return 0;
    }

    // -----------------------------------------------------------------------

    static List<String> concat(List<String> a, List<String> b) {
        List<String> r = new ArrayList<>(a);
        r.addAll(b);
        return r;
    }

    static String fileName(String p) {
        int i = p.lastIndexOf('/');
        return i >= 0 ? p.substring(i + 1) : p;
    }

    static List<String> names(List<String> paths) {
        List<String> r = new ArrayList<>();
        for (String p : paths) r.add(fileName(p));
        return r;
    }

    static String clip(String s) {
        if (s == null) return "";
        return s.length() <= 120 ? s : s.substring(0, 117) + "...";
    }

    static String cap(java.util.Collection<String> items, int max) {
        List<String> l = new ArrayList<>(items);
        if (l.size() <= max) return String.join(", ", l);
        return String.join(", ", l.subList(0, max)) + " ... (+" + (l.size() - max) + " more)";
    }
}
