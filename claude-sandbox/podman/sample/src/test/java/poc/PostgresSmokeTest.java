package poc;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfSystemProperty;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.Statement;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

// Verifieert wat SmokeTest (alpine) NIET kan aantonen:
//
// 1. Een image dat naar een tweede uid chownt. Het postgres-entrypoint chownt
//    $PGDATA naar de postgres-uid; in single-uid modus bestaat die uid niet in
//    de namespace → `chown: ...: Invalid argument` en de container stopt direct.
//    Daarom draait deze test alleen in multi-uid modus (zie smoke-test.sh, die
//    -Dpodman.multiuid zet op basis van /etc/subuid).
// 2. Wachten op een open poort + er echt verkeer overheen. Precies daar loopt
//    rootless podman vast zonder TESTCONTAINERS_HOST_OVERRIDE=localhost:
//    Testcontainers resolvet de container-host dan als de netavark
//    bridge-gateway (bv. 10.88.0.1) terwijl podman op localhost publisht.
//
// Naam eindigt op *Test zodat surefire hem oppakt — zie de noot in SmokeTest.
@Testcontainers
@EnabledIfSystemProperty(named = "podman.multiuid", matches = "true",
        disabledReason = "vereist multi-uid podman (PODMAN_MULTIUID=true + compose.override.podman-multiuid.yml)")
class PostgresSmokeTest {

    @Container
    PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16-alpine");

    @Test
    void queryOverPublishedPort() throws Exception {
        assertTrue(postgres.isRunning(), "Testcontainers kon geen Postgres-container starten");

        try (Connection conn = DriverManager.getConnection(
                     postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword());
             Statement st = conn.createStatement();
             ResultSet rs = st.executeQuery("select 42")) {
            assertTrue(rs.next(), "geen resultaat van 'select 42'");
            assertEquals(42, rs.getInt(1));
        }
    }
}
