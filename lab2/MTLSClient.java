import javax.net.ssl.*;
import java.io.*;
import java.security.*;

public class MTLSClient {
    public static void main(String[] args) throws Exception {
        String host = args.length > 0 ? args[0] : "localhost";
        int port = Integer.parseInt(args.length > 1 ? args[1] : "8443");

        KeyStore ks = KeyStore.getInstance("PKCS12");
        ks.load(new FileInputStream("client.p12"), "changeit".toCharArray());
        KeyManagerFactory kmf = KeyManagerFactory.getInstance("SunX509");
        kmf.init(ks, "changeit".toCharArray());

        KeyStore ts = KeyStore.getInstance("JKS");
        ts.load(new FileInputStream("truststore.jks"), "changeit".toCharArray());
        TrustManagerFactory tmf = TrustManagerFactory.getInstance("SunX509");
        tmf.init(ts);

        SSLContext ctx = SSLContext.getInstance("TLSv1.3");
        ctx.init(kmf.getKeyManagers(), tmf.getTrustManagers(), null);

        SSLSocketFactory sf = ctx.getSocketFactory();
        try (SSLSocket sock = (SSLSocket) sf.createSocket(host, port)) {
            sock.startHandshake();

            SSLSession session = sock.getSession();
            System.out.println("Protocol:   " + session.getProtocol());
            System.out.println("Cipher:     " + session.getCipherSuite());
            System.out.println("Server CN:  " +
                ((java.security.cert.X509Certificate) session.getPeerCertificates()[0])
                    .getSubjectX500Principal().getName());

            OutputStream out = sock.getOutputStream();
            out.write("GET / HTTP/1.0\r\nHost: localhost\r\n\r\n".getBytes());
            out.flush();

            BufferedReader in = new BufferedReader(new InputStreamReader(sock.getInputStream()));
            String line;
            while ((line = in.readLine()) != null) System.out.println(line);
        }
    }
}
