package com.hyperos.fcm.patcher.common;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.Enumeration;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import java.util.zip.CRC32;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;

public class AlignedJarRepacker {

    private static class CountingOutputStream extends FilterOutputStream {
        private long count = 0;

        public CountingOutputStream(OutputStream out) {
            super(out);
        }

        @Override
        public void write(int b) throws IOException {
            out.write(b);
            count++;
        }

        @Override
        public void write(byte[] b, int off, int len) throws IOException {
            out.write(b, off, len);
            count += len;
        }

        public long getCount() {
            return count;
        }
    }

    /**
     * Repacks an Android Framework JAR file with multi-dex support and guaranteed 4-byte DEX alignment.
     * ART directly mmap's uncompressed (STORED) .dex files from JARs; if byte offset % 4 != 0,
     * system_server aborts with SIGBUS on boot.
     *
     * @param sourceJar Original stock JAR from device.
     * @param replacementDexMap Map of DEX filename to replacement bytes (e.g. "classes.dex" -> byte[]).
     * @param destJar Target output JAR.
     */
    public static void repackJar(File sourceJar, Map<String, byte[]> replacementDexMap, File destJar) throws IOException {
        try (ZipFile srcZip = new ZipFile(sourceJar);
             FileOutputStream fos = new FileOutputStream(destJar);
             BufferedOutputStream bos = new BufferedOutputStream(fos);
             CountingOutputStream cos = new CountingOutputStream(bos);
             ZipOutputStream zos = new ZipOutputStream(cos)) {

            Enumeration<? extends ZipEntry> entries = srcZip.entries();
            byte[] buffer = new byte[65536];
            Set<String> writtenReplacements = new HashSet<>();

            while (entries.hasMoreElements()) {
                ZipEntry srcEntry = entries.nextElement();
                String entryName = srcEntry.getName();

                byte[] dexBytes = replacementDexMap.get(entryName);
                if (dexBytes != null) {
                    // 1. Modified DEX replacement
                    writeAlignedStoredEntry(zos, cos, entryName, dexBytes);
                    writtenReplacements.add(entryName);
                } else if (entryName.endsWith(".dex")) {
                    // 2. Unmodified secondary DEX - read original bytes and write as aligned STORED
                    byte[] originalDexBytes;
                    try (InputStream is = srcZip.getInputStream(srcEntry);
                         ByteArrayOutputStream baos = new ByteArrayOutputStream()) {
                        int read;
                        while ((read = is.read(buffer)) != -1) {
                            baos.write(buffer, 0, read);
                        }
                        originalDexBytes = baos.toByteArray();
                    }
                    writeAlignedStoredEntry(zos, cos, entryName, originalDexBytes);
                } else {
                    // 3. Standard Non-DEX entry (e.g. META-INF)
                    ZipEntry copyEntry = new ZipEntry(entryName);
                    copyEntry.setTime(srcEntry.getTime());
                    copyEntry.setMethod(srcEntry.getMethod() == ZipEntry.STORED ? ZipEntry.STORED : ZipEntry.DEFLATED);
                    if (copyEntry.getMethod() == ZipEntry.STORED) {
                        copyEntry.setSize(srcEntry.getSize());
                        copyEntry.setCompressedSize(srcEntry.getSize());
                        copyEntry.setCrc(srcEntry.getCrc());
                    }

                    zos.putNextEntry(copyEntry);
                    try (InputStream is = srcZip.getInputStream(srcEntry)) {
                        int read;
                        while ((read = is.read(buffer)) != -1) {
                            zos.write(buffer, 0, read);
                        }
                    }
                    zos.closeEntry();
                }
            }

            // 4. Any newly created DEX entries (e.g. classes3.dex) not present in sourceJar
            for (Map.Entry<String, byte[]> extraEntry : replacementDexMap.entrySet()) {
                if (!writtenReplacements.contains(extraEntry.getKey())) {
                    writeAlignedStoredEntry(zos, cos, extraEntry.getKey(), extraEntry.getValue());
                }
            }
        }
    }

    private static void writeAlignedStoredEntry(ZipOutputStream zos, CountingOutputStream cos, String entryName, byte[] data) throws IOException {
        long lfhOffset = cos.getCount();
        byte[] nameBytes = entryName.getBytes(StandardCharsets.UTF_8);

        // ZIP Local File Header fixed size = 30 bytes
        // Data offset = lfhOffset + 30 + nameBytes.length + extraBytes.length
        long unpaddedDataOffset = lfhOffset + 30 + nameBytes.length;
        int padding = (int) ((4 - (unpaddedDataOffset % 4)) % 4);

        CRC32 crc = new CRC32();
        crc.update(data);

        ZipEntry entry = new ZipEntry(entryName);
        entry.setMethod(ZipEntry.STORED);
        entry.setSize(data.length);
        entry.setCompressedSize(data.length);
        entry.setCrc(crc.getValue());
        entry.setTime(System.currentTimeMillis());

        if (padding > 0) {
            entry.setExtra(new byte[padding]);
        }

        zos.putNextEntry(entry);
        zos.write(data);
        zos.closeEntry();

        long actualDataOffset = lfhOffset + 30 + nameBytes.length + padding;
        if (actualDataOffset % 4 != 0) {
            throw new IllegalStateException("CRITICAL: Failed to 4-byte align DEX entry " + entryName + " (offset: " + actualDataOffset + ")");
        }
    }
}
