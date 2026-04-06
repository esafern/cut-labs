import java.net.*;
import java.io.*;

public class StallServer {
    public static void main(String[] args) throws Exception {
        int port = 7777;
        int stallSeconds = Integer.parseInt(args.length > 0 ? args[0] : "15");
        int recvSize = Integer.parseInt(args.length > 1 ? args[1] : "64");
        int recvDelay = Integer.parseInt(args.length > 2 ? args[2] : "100");

        ServerSocket ss = new ServerSocket();
        ss.setReceiveBufferSize(4096);
        ss.bind(new InetSocketAddress("127.0.0.1", port));
        System.out.printf("Listening on %d (rcvbuf=%d)%n", port, ss.getReceiveBufferSize());

        try (Socket client = ss.accept()) {
            System.out.printf("Accepted. Stalling for %d seconds...%n", stallSeconds);
            Thread.sleep(stallSeconds * 1000L);

            System.out.printf("Waking up. Slow read: %d bytes every %d ms%n", recvSize, recvDelay);
            InputStream in = client.getInputStream();
            byte[] buf = new byte[recvSize];
            int totalRead = 0;
            int n;
            while ((n = in.read(buf)) != -1) {
                totalRead += n;
                System.out.printf("Read %d bytes (total: %d)%n", n, totalRead);
                Thread.sleep(recvDelay);
            }
            System.out.printf("Connection closed. Total read: %d bytes%n", totalRead);
        }
        ss.close();
    }
}
