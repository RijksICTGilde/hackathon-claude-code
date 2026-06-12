package poc;

import org.junit.jupiter.api.Test;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import static org.junit.jupiter.api.Assertions.assertTrue;

// Naam MOET op *Test eindigen: `mvn test` draait surefire, en surefire pakt
// alleen *Test/Test*/*Tests — NIET *IT (dat is failsafe). Een *IT-naam wordt
// stil overgeslagen → groene build zonder dat de container ooit startte.
@Testcontainers
class SmokeTest {

    @Container
    GenericContainer<?> alpine =
            new GenericContainer<>("alpine:3.20").withCommand("sleep", "300");

    @Test
    void containerStartsViaPodman() {
        assertTrue(alpine.isRunning(), "Testcontainers kon geen nested container starten");
    }
}
