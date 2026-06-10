package poc;

import org.junit.jupiter.api.Test;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import static org.junit.jupiter.api.Assertions.assertTrue;

@Testcontainers
class SmokeIT {

    @Container
    GenericContainer<?> alpine =
            new GenericContainer<>("alpine:3.20").withCommand("sleep", "300");

    @Test
    void containerStartsViaPodman() {
        assertTrue(alpine.isRunning(), "Testcontainers kon geen nested container starten");
    }
}
