module networking.fibs.connection;

import core.time;
import std.algorithm : startsWith;
import std.array;
import std.socket;
import std.stdio;
import std.variant;
import networking.connection;
import networking.fibs.clipmessages;

/**
 * Handles connection with FIBS server as well as formatting requests and parsing
 * responses.
 */
class FIBSConnection : Connection {
    // Create a new connection to a FIBS server and attempt to login
    this(Address serverAddress, string username, string password) {
        super(serverAddress);

        // Wait for login prompt...
        while (true) {
            try {
                auto l = this.readline(25.msecs);
            } catch (TimeoutException e) {
                if (this.recBuffer.startsWith("login:")) {
                    this.recBuffer = "";
                    break;
                }
            }
        }

        this.writeline("login backgammony-1.0.0 1008 " ~ username ~ " " ~ password);

        // Throw expception if receive another login prompt otherwise return
        // active connection ready to exchange messages messages. This has funny
        // behavious. Usually a newline character will _not_ be emitted after the
        // "login:" prompt but sometimes and a random CLIP message will be printed
        // after and so a newline is found.
        try {
            this.readline(500.msecs); // Server will send a new line first
            auto l = this.readline(500.msecs);

            if (l.startsWith("login:")) {
                throw new Exception("Authentication Failure");
            }

            this.recBuffer = l ~ "\r\n" ~ recBuffer;
        } catch (TimeoutException e) {
            throw new Exception("Authentication Failure");
        }

        writeln("Authenticated successfully to FIBS server ", serverAddress);
    }

    /*
     * Overrided writeline to send carriage return as well
     */
    override void writeline(string s = "") {
        if (this._debug) {
            writeln("NETSND: ", s);
        }
        this.conn.send(s ~ "\r\n");
    }

    /**
     * Read a CLIP message
     */
    Variant readMessage(Duration timeout) {
        import std.datetime.stopwatch;
        auto timer = new StopWatch(AutoStart.yes);

        string[] lines;

        // Skip empty lines and useless 6
        do {
            lines ~= this.readline(timeout);
            if (lines[0] == "" || lines[0] == "6") {
                lines = [];
                continue;
            }

            // Is this a multi line output?
            string clipIdentifier = lines[0].split()[0];
            if (clipIdentifier == "3" || clipIdentifier == "7") {
                string lastLine = lines[$-1];
                if (lastLine.length) {
                    string lastClipIdentifier = lastLine.split()[0];
                    if (clipIdentifier == "3" && lastClipIdentifier == "4") {
                        break;
                    }
                    if (clipIdentifier == "7" && lastClipIdentifier == "8") {
                        break;
                    }
                }
            } else {
                break;
            }

        } while (timeout == Duration.zero || timer.peek < timeout);

        Variant v;
        switch (lines[0].split()[0]) {
            case "1":
                assert(lines.length == 1);
                v = CLIPWelcome(lines[0]);
                break;
            case "2":
                assert(lines.length == 1);
                v = CLIPOwnInfo(lines[0]);
                break;
            case "3":
                assert(lines.length >= 2);
                v = CLIPMOTD(lines);
                break;
            case "5":
                v = CLIPWho(lines[0]);
                break;
            default:
                v = "===> " ~ lines[0];
                break;
        }

        return v;
    }
}
