package ca.onpoint.ibridge.api;

import java.time.DateTimeException;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** The read-only subset of shared/operations.json. No arbitrary routes or writes. */
public enum ReadOperation {
    CALENDARS("calendar.list", "/calendars", true),
    EVENTS("calendar.events.list", "/events", true,
            text("calendar_id", "Calendar ID", true, 512),
            date("start", "Start (RFC 3339)"), date("end", "End (RFC 3339)")),
    REMINDER_LISTS("reminders.lists", "/reminders/lists", true),
    REMINDERS("reminders.list", "/reminders", true,
            text("list_id", "List ID", true, 512),
            new Argument("completed", "Completed (true or false)", false, null, Kind.BOOLEAN, 0, 0)),
    CONTACTS("contacts.search", "/contacts", true, query()),
    DRIVE_ROOTS("drive.roots", "/drive/roots", true),
    DRIVE_LIST("drive.list", "/drive/files", true,
            text("root_id", "Root ID", true, 512), path(false)),
    DRIVE_SEARCH("drive.search", "/drive/search", true,
            text("root_id", "Root ID", true, 512), query()),
    DRIVE_READ("drive.read", "/drive/content", false,
            text("root_id", "Root ID", true, 512), path(true),
            new Argument("max_bytes", "Maximum bytes (1–262144)", false, "262144", Kind.INTEGER, 1, 262144)),
    NOTE_FOLDERS("notes.folders", "/notes/folders", true),
    NOTES_SEARCH("notes.search", "/notes", true, query(), text("folder_id", "Folder ID", false, 512)),
    NOTES_READ("notes.read", "/notes/{note_id}", false, text("note_id", "Note ID", true, 512)),
    MESSAGE_CHATS("messages.chats", "/messages/chats", true),
    MESSAGES_SEARCH("messages.search", "/messages/search", true,
            query(), text("chat_id", "Chat ID", false, 512)),
    MESSAGES_READ("messages.read", "/messages/chats/{chat_id}/messages", true,
            text("chat_id", "Chat ID", true, 512));

    public enum Kind { TEXT, INTEGER, BOOLEAN, DATE, PATH }

    public static final class Argument {
        public final String name;
        public final String label;
        public final boolean required;
        public final String defaultValue;
        public final Kind kind;
        public final int minimum;
        public final int maximum;

        private Argument(String name, String label, boolean required, String defaultValue,
                         Kind kind, int minimum, int maximum) {
            this.name = name;
            this.label = label;
            this.required = required;
            this.defaultValue = defaultValue;
            this.kind = kind;
            this.minimum = minimum;
            this.maximum = maximum;
        }
    }

    public final String capability;
    public final String route;
    private final boolean paginated;
    private final List<Argument> arguments;
    private static final Pattern TIMESTAMP = Pattern.compile(
            "(\\d{4})-(\\d{2})-(\\d{2})T(\\d{2}):(\\d{2}):(\\d{2})(?:\\.(\\d+))?(Z|([+-])(\\d{2}):(\\d{2}))");

    ReadOperation(String capability, String route, boolean paginated, Argument... specific) {
        this.capability = capability;
        this.route = route;
        this.paginated = paginated;
        List<Argument> fields = new ArrayList<>(Arrays.asList(specific));
        if (paginated) {
            fields.add(new Argument("limit", "Limit (1–100)", false, "50", Kind.INTEGER, 1, 100));
            fields.add(text("cursor", "Cursor", false, 4096));
        }
        this.arguments = Collections.unmodifiableList(fields);
    }

    public boolean paginated() {
        return paginated;
    }

    public List<Argument> arguments() {
        return arguments;
    }

    public static ReadOperation forCapability(String capability) {
        for (ReadOperation operation : values()) {
            if (operation.capability.equals(capability)) return operation;
        }
        throw new BridgeException("invalid_arguments", "Choose a supported read operation.");
    }

    Map<String, String> validate(Map<String, String> supplied) {
        if (supplied == null) throw invalid();
        Map<String, String> result = new LinkedHashMap<>();
        for (String key : supplied.keySet()) {
            boolean declared = false;
            for (Argument argument : arguments) declared |= argument.name.equals(key);
            if (!declared) throw invalid();
        }
        for (Argument argument : arguments) {
            if (argument.required && !supplied.containsKey(argument.name)) throw invalid();
            String value = supplied.containsKey(argument.name)
                    ? supplied.get(argument.name) : argument.defaultValue;
            if (value == null) {
                if (supplied.containsKey(argument.name)) throw invalid();
                continue;
            }
            validateValue(argument, value);
            if (route.contains("{" + argument.name + "}") && (value.equals(".") || value.equals(".."))) {
                throw invalid();
            }
            result.put(argument.name, value);
        }
        if (result.containsKey("start") && timestamp(result.get("end")).compareTo(timestamp(result.get("start"))) <= 0) {
            throw new BridgeException("invalid_arguments", "End must be later than start.");
        }
        return result;
    }

    private static void validateValue(Argument argument, String value) {
        if (argument.kind == Kind.INTEGER) {
            if (!value.matches("[0-9]+")) throw invalid();
            try {
                int number = Integer.parseInt(value);
                if (number < argument.minimum || number > argument.maximum) throw invalid();
            } catch (NumberFormatException exception) {
                throw invalid();
            }
            return;
        }
        if (argument.kind == Kind.BOOLEAN) {
            if (!value.equals("true") && !value.equals("false")) throw invalid();
            return;
        }
        int length = value.codePointCount(0, value.length());
        if (length < argument.minimum || length > argument.maximum) throw invalid();
        for (int index = 0; index < value.length(); index++) {
            char character = value.charAt(index);
            if ((character < 32 && character != '\n' && character != '\t') || character == 127) throw invalid();
            if (Character.isHighSurrogate(character)) {
                if (++index >= value.length() || !Character.isLowSurrogate(value.charAt(index))) throw invalid();
            } else if (Character.isLowSurrogate(character)) throw invalid();
        }
        if (argument.kind == Kind.DATE) timestamp(value);
        if (argument.kind == Kind.PATH) {
            if (value.startsWith("/") || value.contains("\\")) throw invalidPath();
            for (String part : value.split("/", -1)) {
                if (part.equals(".") || part.equals("..")) throw invalidPath();
            }
        }
    }

    // RFC 3339 allows offsets through 23:59; java.time.ZoneOffset stops at 18:00.
    // Compare exact fractional instants after explicitly checking offset components.
    private static BigDecimal timestamp(String value) {
        Matcher match = TIMESTAMP.matcher(value);
        if (!match.matches()) throw invalidDate();
        try {
            String fraction = match.group(7);
            int year = Integer.parseInt(match.group(1));
            if (year == 0) throw invalidDate();
            LocalDateTime local = LocalDateTime.of(year, Integer.parseInt(match.group(2)),
                    Integer.parseInt(match.group(3)), Integer.parseInt(match.group(4)), Integer.parseInt(match.group(5)),
                    Integer.parseInt(match.group(6)));
            if (!match.group(8).equals("Z")) {
                int hours = Integer.parseInt(match.group(10));
                int minutes = Integer.parseInt(match.group(11));
                if (hours > 23 || minutes > 59) throw invalidDate();
                int offset = (hours * 60 + minutes) * (match.group(9).equals("-") ? -1 : 1);
                local = local.minusMinutes(offset);
            }
            BigDecimal seconds = BigDecimal.valueOf(local.toEpochSecond(ZoneOffset.UTC));
            return fraction == null ? seconds : seconds.add(new BigDecimal("0." + fraction));
        } catch (DateTimeException | NumberFormatException exception) {
            throw invalidDate();
        }
    }

    private static Argument text(String name, String label, boolean required, int maximum) {
        return new Argument(name, label, required, null, Kind.TEXT, 1, maximum);
    }

    private static Argument query() {
        return text("query", "Search text", true, 1000);
    }

    private static Argument date(String name, String label) {
        return new Argument(name, label, true, null, Kind.DATE, 1, 40);
    }

    private static Argument path(boolean required) {
        return new Argument("path", "Relative path", required, required ? null : "", Kind.PATH, required ? 1 : 0, 2048);
    }

    private static BridgeException invalid() {
        return new BridgeException("invalid_arguments", "Check the required fields and allowed argument values.");
    }

    private static BridgeException invalidPath() {
        return new BridgeException("invalid_arguments", "Drive paths must stay relative to the selected root without dot segments or backslashes.");
    }

    private static BridgeException invalidDate() {
        return new BridgeException("invalid_arguments", "Dates must be valid RFC 3339 timestamps with an explicit timezone.");
    }
}
