/*
 * Suite D (concurrency): reads every entry of every jar in a Maven local
 * repository, so that a jar two builds wrote at once cannot pass for a good
 * one.
 *
 *     java VerifyJars.java <repository dir>
 *
 * Run by test/container/scan-repo.sh inside homecrew-dev-runtime:jdk25, on
 * the Maven volume the twelve builds shared. Single file, JDK only - `java
 * File.java` compiles it in memory and writes nothing, which matters: the
 * same scan runs against your REAL Maven volume in D-REAL.
 *
 * WHY EVERY BYTE AND NOT JUST "IT OPENS". A jar that opens can still be
 * broken: the central directory sits at the END of the file, so a jar whose
 * tail was written by one process and whose middle by another opens fine and
 * fails only when the one class that landed in the damaged stretch is loaded -
 * at run time, in the application, long after the build said BUILD SUCCESS.
 * So every jar is read twice, once from each end:
 *
 *   1. through the central directory (ZipFile): each entry inflated to the
 *      end, its CRC-32 and length compared with what the directory says;
 *   2. front to back through the local headers (ZipInputStream), which is
 *      how a truncated or spliced file shows up even where the directory at
 *      the end is intact - every local header must name an entry the
 *      directory lists, the counts must agree, and ZipInputStream checks each
 *      entry's CRC itself. Pass 1 alone misses damage to a local header: it
 *      only takes the header's signature and lengths from there.
 *
 * A jar that is not a zip at all - an HTML error page saved under a .jar name,
 * a zero-byte file - fails on open, which is the point.
 *
 * Output, on stdout:
 *     BROKEN <path>: <reason>          one line per broken jar
 *     VERIFY-JARS jars=<n> entries=<m> bytes=<b> broken=<k>
 * Exit status: 0 = every jar read cleanly; 1 = at least one BROKEN line;
 * 2 = usage, or the directory could not be walked.
 *
 * The .locks directory is skipped: it holds the resolver's lock files, which
 * are not artifacts.
 */

import java.io.BufferedInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.FileVisitResult;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.zip.CRC32;
import java.util.zip.ZipEntry;
import java.util.zip.ZipException;
import java.util.zip.ZipFile;
import java.util.zip.ZipInputStream;

public class VerifyJars {

    private static long entries;
    private static long bytes;

    public static void main(String[] args) {
        if (args.length != 1) {
            System.err.println("usage: java VerifyJars.java <repository dir>");
            System.exit(2);
        }
        Path root = Paths.get(args[0]);
        if (!Files.isDirectory(root)) {
            System.err.println("not a directory: " + root);
            System.exit(2);
        }

        List<Path> jars = new ArrayList<>();
        try {
            Files.walkFileTree(root, new SimpleFileVisitor<Path>() {
                @Override
                public FileVisitResult preVisitDirectory(Path dir, BasicFileAttributes attrs) {
                    return ".locks".equals(String.valueOf(dir.getFileName())) ? FileVisitResult.SKIP_SUBTREE : FileVisitResult.CONTINUE;
                }

                @Override
                public FileVisitResult visitFile(Path file, BasicFileAttributes attrs) {
                    if (attrs.isRegularFile() && file.getFileName().toString().endsWith(".jar")) {
                        jars.add(file);
                    }
                    return FileVisitResult.CONTINUE;
                }

                // A file that cannot even be listed is reported, not skipped:
                // silently leaving it out would make the scan look cleaner
                // than the repository is.
                @Override
                public FileVisitResult visitFileFailed(Path file, IOException e) {
                    if (file.getFileName() != null && file.getFileName().toString().endsWith(".jar")) {
                        jars.add(file);
                    } else {
                        System.out.println("UNREADABLE " + file + ": " + e);
                    }
                    return FileVisitResult.CONTINUE;
                }
            });
        } catch (IOException e) {
            System.err.println("cannot walk " + root + ": " + e);
            System.exit(2);
        }
        jars.sort(null);

        int broken = 0;
        byte[] buf = new byte[1 << 16];
        for (Path jar : jars) {
            try {
                verify(jar, buf);
            } catch (IOException | RuntimeException e) {
                broken++;
                String why = e.getMessage() == null ? e.getClass().getName() : e.getClass().getSimpleName() + ": " + e.getMessage();
                System.out.println("BROKEN " + jar + ": " + printable(why));
            }
        }
        System.out.println("VERIFY-JARS jars=" + jars.size() + " entries=" + entries + " bytes=" + bytes + " broken=" + broken);
        System.exit(broken == 0 ? 0 : 1);
    }

    // A damaged entry name can hold any byte at all; the report stays one
    // line of plain ASCII.
    private static String printable(String s) {
        StringBuilder b = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            b.append(c >= 0x20 && c < 0x7f ? c : '?');
        }
        return b.toString();
    }

    private static void verify(Path jar, byte[] buf) throws IOException {
        Set<String> names = new HashSet<>();
        long count = 0;
        long read = 0;
        try (ZipFile zip = new ZipFile(jar.toFile())) {
            Enumeration<? extends ZipEntry> en = zip.entries();
            while (en.hasMoreElements()) {
                ZipEntry e = en.nextElement();
                CRC32 crc = new CRC32();
                long n = 0;
                try (InputStream in = zip.getInputStream(e)) {
                    int r;
                    while ((r = in.read(buf)) > 0) {
                        crc.update(buf, 0, r);
                        n += r;
                    }
                }
                // -1 means the directory did not record it (it always does
                // for a jar written by the JDK or Maven, but a stranger
                // archive is not wrong for leaving it out).
                if (e.getSize() >= 0 && n != e.getSize()) {
                    throw new ZipException(e.getName() + ": read " + n + " bytes, the central directory says " + e.getSize());
                }
                if (e.getCrc() >= 0 && crc.getValue() != e.getCrc()) {
                    throw new ZipException(e.getName() + ": CRC-32 " + Long.toHexString(crc.getValue()) + ", the central directory says " + Long.toHexString(e.getCrc()));
                }
                names.add(e.getName());
                count++;
                read += n;
            }
        }
        long local = 0;
        try (ZipInputStream zin = new ZipInputStream(new BufferedInputStream(Files.newInputStream(jar), 1 << 16))) {
            ZipEntry e;
            while ((e = zin.getNextEntry()) != null) {
                while (zin.read(buf) > 0) {
                    // read to the end: that is when ZipInputStream checks the CRC
                }
                if (!names.contains(e.getName())) {
                    throw new ZipException("a local header names '" + e.getName() + "', which the central directory does not list");
                }
                local++;
            }
        }
        if (local != count) {
            throw new ZipException("the local headers hold " + local + " entries, the central directory " + count);
        }
        entries += count;
        bytes += read;
    }
}
