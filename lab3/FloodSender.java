import java.net.*;
import java.io.*;

public class FloodSender {
    public static void main(String[] args) throws Exception {
        String host = "127.0.0.1";
        int port = 7777;
        int chunkSize = 8192;
        int totalMB = 2;

        try (Socket sock = new Socket(host, port)) {
            sock.setSendBufferSize(65536);
            System.out.printf("Connected. Sending %d MB in %d-byte chunks%n", totalMB, chunkSize);

            OutputStream out = sock.getOutputStream();
            byte[] data = new byte[chunkSize];
            java.util.Arrays.fill(data, (byte) 'X');

            long totalSent = 0;
            long target = totalMB * 1024L * 1024L;
            long start = System.currentTimeMillis();

            while (totalSent < target) {
                try {
                    out.write(data);
                    totalSent += chunkSize;
                    if (totalSent % (256 * 1024) == 0) {
                        long elapsed = System.currentTimeMillis() - start;
                        System.out.printf("Sent %d KB in %d ms%n", totalSent / 1024, elapsed);
                    }
                } catch (IOException e) {
                    System.out.printf("Write blocked/failed at %d KB: %s%n", totalSent / 1024, e.getMessage());
                    break;
                }
            }
            long elapsed = System.currentTimeMillis() - start;
            System.out.printf("Done. Sent %d KB in %d ms%n", totalSent / 1024, elapsed);
        }
    }
}
