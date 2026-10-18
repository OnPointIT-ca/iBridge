package ca.onpoint.ibridge.api;

/** A safe, local error description. Never contains a server body or transport exception. */
public final class BridgeException extends RuntimeException {
    private final String code;

    BridgeException(String code, String message) {
        super(message);
        this.code = code;
    }

    public String getCode() {
        return code;
    }
}
