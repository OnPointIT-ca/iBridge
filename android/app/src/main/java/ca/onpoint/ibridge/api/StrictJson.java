package ca.onpoint.ibridge.api;

import java.util.HashSet;
import java.util.Set;

/** Android's JSONTokener accepts non-JSON syntax; check the wire grammar first. */
final class StrictJson {
    private final String source;
    private int index;

    private StrictJson(String source) {
        this.source = source;
    }

    static void validate(String source) {
        StrictJson parser = new StrictJson(source);
        parser.value(0);
        parser.space();
        if (parser.index != source.length()) throw invalid();
    }

    private void value(int depth) {
        if (depth > 64) throw invalid();
        space();
        if (index >= source.length()) throw invalid();
        char character = source.charAt(index);
        if (character == '{') {
            index++;
            space();
            if (take('}')) return;
            Set<String> keys = new HashSet<>();
            do {
                space();
                String key = string();
                if (!keys.add(key)) throw invalid();
                space();
                require(':');
                value(depth + 1);
                space();
                if (take('}')) return;
                require(',');
            } while (true);
        } else if (character == '[') {
            index++;
            space();
            if (take(']')) return;
            do {
                value(depth + 1);
                space();
                if (take(']')) return;
                require(',');
            } while (true);
        } else if (character == '"') {
            string();
        } else if (character == 't') {
            literal("true");
        } else if (character == 'f') {
            literal("false");
        } else if (character == 'n') {
            literal("null");
        } else {
            number();
        }
    }

    private String string() {
        require('"');
        StringBuilder decoded = new StringBuilder();
        while (index < source.length()) {
            char character = source.charAt(index++);
            if (character == '"') return decoded.toString();
            if (character < 32) throw invalid();
            if (character == '\\') {
                if (index >= source.length()) throw invalid();
                char escape = source.charAt(index++);
                switch (escape) {
                    case '"': character = '"'; break;
                    case '\\': character = '\\'; break;
                    case '/': character = '/'; break;
                    case 'b': character = '\b'; break;
                    case 'f': character = '\f'; break;
                    case 'n': character = '\n'; break;
                    case 'r': character = '\r'; break;
                    case 't': character = '\t'; break;
                    case 'u':
                        if (index + 4 > source.length()) throw invalid();
                        int value = 0;
                        for (int digit = 0; digit < 4; digit++) {
                            char hex = source.charAt(index++);
                            int number = "0123456789abcdef".indexOf(Character.toLowerCase(hex));
                            if (number < 0) throw invalid();
                            value = value * 16 + number;
                        }
                        character = (char) value;
                        break;
                    default: throw invalid();
                }
            }
            decoded.append(character);
        }
        throw invalid();
    }

    private void number() {
        take('-');
        if (!take('0')) {
            if (index >= source.length() || source.charAt(index) < '1' || source.charAt(index) > '9') throw invalid();
            digits();
        }
        if (take('.')) {
            int start = index;
            digits();
            if (index == start) throw invalid();
        }
        if (take('e') || take('E')) {
            if (!take('+')) take('-');
            int start = index;
            digits();
            if (index == start) throw invalid();
        }
    }

    private void digits() {
        while (index < source.length() && source.charAt(index) >= '0' && source.charAt(index) <= '9') index++;
    }

    private void literal(String literal) {
        if (!source.startsWith(literal, index)) throw invalid();
        index += literal.length();
    }

    private void space() {
        while (index < source.length() && " \t\r\n".indexOf(source.charAt(index)) >= 0) index++;
    }

    private boolean take(char character) {
        if (index < source.length() && source.charAt(index) == character) {
            index++;
            return true;
        }
        return false;
    }

    private void require(char character) {
        if (!take(character)) throw invalid();
    }

    private static BridgeException invalid() {
        return new BridgeException("invalid_response", "Bridge returned invalid JSON.");
    }
}
