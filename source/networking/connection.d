module networking.connection;

import core.time;
import core.thread;
import std.socket;
import std.stdio;
import std.string;
import std.typecons : tuple;

enum protocolHeader = "TBP/1.0";

struct ConnectionHeaders {
    string playerId;
    string userName;
}

// Wrapper around network connections. Provides helper functions and IP version
// agnosticism. Handles initial connection.
class Connection {
    private Socket conn;
    private Address address;
    bool isHost;

    /// Create a Connection and connects to address as a client
    this(Address address, ConnectionHeaders headers) {
        writeln("Attempting connection to ", address);
        this.address = address;
        this.isHost = false;
        this.conn = new TcpSocket(address);

        try {
            this.writeline(protocolHeader);
            this.writeHeaders(headers);

            this.readline(2.seconds);
            ConnectionHeaders resp = readHeaders!ConnectionHeaders(2.seconds);
        } catch (Exception e) {
            this.close();
            throw e;
        }
    }

    /// Create a Connection as a host. Assumes socket is already active.
    this(Socket socket, ConnectionHeaders headers) {
        this.address = socket.remoteAddress;
        this.conn = socket;
        this.isHost = true;

        this.readline(2.seconds);
        ConnectionHeaders resp = readHeaders!ConnectionHeaders(1.seconds);
        this.writeline(protocolHeader);
        this.writeHeaders(headers);
    }

    /// Close the socket
    void close() {
        conn.shutdown(SocketShutdown.BOTH);
        conn.close();
    }

    T readHeaders(T)(Duration timeout = Duration.zero) {
        import std.datetime.stopwatch;
        auto timer = new StopWatch(AutoStart.yes);

        T ret;

        while (true) {
            auto remainingTime = timeout == Duration.zero ? Duration.zero : timeout - timer.peek;
            auto line = readline(remainingTime);
            if (!line.length) break;
            if (line.indexOf(":") == -1) throw new Exception("Invalid header line: No colon");

            string key = line[0..line.indexOf(":")].chomp();
            string val = line[line.indexOf(":")+1..$].chomp();

            static foreach (string member; [ __traits(allMembers, T) ]) {
                if (key.toLower == member.toLower) {
                }
            }
        }

        return ret;
    }

    void writeHeaders(T)(T header, Duration timeout = Duration.zero) {
        static foreach (string member; [ __traits(allMembers, T) ]) {
            if (__traits(getMember, header, member).length) {
                this.writeline(member ~ ": " ~ __traits(getMember, header, member));
            }
        }
        this.writeline();
    }

    /// Read a line (newline excluded) syncronously from the current connection.
    /// ARGS:
    ///   timeout: How long before throwing timeout exception. Leave for unlimited.
    string recBuffer;
    string readline(Duration timeout = Duration.zero) {
        import std.datetime.stopwatch;
        auto timer = new StopWatch(AutoStart.yes);

        do {
            auto buffer = new ubyte[2056];
            ptrdiff_t amountRead;
            conn.blocking = false;
            amountRead = conn.receive(buffer);
            conn.blocking = true;

            if (amountRead == 0) {
                throw new Exception("Connection readline: Connection is closed");
            }

            if (amountRead == Socket.ERROR) {
                if (conn.getErrorText() == "Success") {
                    amountRead = 0;
                } else {
                    throw new Exception("Socket Error: ", conn.getErrorText());
                }
            }
            recBuffer ~= cast(string) buffer[0..amountRead];

            if (recBuffer.indexOf('\n') != -1) break;

            import core.thread;
            Thread.sleep(50.msecs);
        } while (timeout == Duration.zero || timer.peek < timeout);

        if (timeout != Duration.zero && timer.peek > timeout) {
            throw new Exception("Connection readline timeout");
        }

        auto nlIndex = recBuffer.indexOf('\n');
        if (nlIndex != -1) {
            string ret = recBuffer[0..nlIndex];
            recBuffer = recBuffer[nlIndex+1..$];
            writeln("NETGET: ", ret);
            return ret;
        } else {
            throw new Exception("No newline is available");
        }
    }

    /// Write line to the connection.
    void writeline(string s = "") {
        writeln("NETSND: ", s);
        conn.send(s ~ "\n");
    }
}