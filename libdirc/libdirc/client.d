module libdirc.client;

import core.time;
import std.algorithm;
import std.array;
import std.ascii : isDigit;
import std.container.slist;
import std.conv;
import std.exception;
import std.range;
import std.regex;
import std.socket;
import std.string;
import std.uni;

import libdirc.channel;
import libdirc.helper;
import libdirc.user;
import libdirc.util;

debug import std.stdio;

// https://github.com/JakobOvrum/Dirk/blob/ec8acb2441fc0ec14b186971cc15ddcd170e5086/source/irc/protocol.d#L13-L20
private enum IRC_MAX_LEN      = 512;
private enum IRC_USERHOST_LEN = 63 + 10 + 1;
private enum LINE_LENGTH      = (IRC_MAX_LEN - "\r\n".length) - IRC_USERHOST_LEN;

private auto ctcpRegex = ctRegex!(`\x01[^\x01]+\x01`);

/**
	A client used for sending and reading data to/from an IRC server.
	Automatically tracks users and channels.

	See_Also:
		IrcUser, IrcChannel
*/
class IrcClient
{
private:
	Socket socket;
	MonoTime lastNetTime;
	bool timingOut;

	bool _connected;
	char[IRC_MAX_LEN] in_buffer;
	char[] overflow;

	char[] _channelUserModes    = [ 'o', 'v' ];
	char[] _channelUserPrefixes = [ '@', '+' ];

	// see: https://github.com/JakobOvrum/Dirk/blob/master/source/irc/client.d#L97
	// CHANMODES
	string channelListModes = "b";       // Type A
	string channelParameterizedModes;    // Type B
	string channelNullaryRemovableModes; // Type C
	string channelSettingModes;          // Type D

	uint _maxNickLength;

	IrcUser me;

	string _networkName;

	void sendNick()
	{
		raw(IrcCommand.Nick ~ ' ' ~ nickName);
	}

public:
	// TODO: both private
	IrcChannel[string] channels;
	SList!IrcUser users;

	/**
		Constructs a new `IrcClient` and self (`IrcUser`) instance.

		Params:
			nickName = The nick name to use on this client.
			userName = The user name to use on this client.
			realName = The "real name" to use on this client (optional).

		See_Also:
			IrcUser
	*/
	this(in string nickName, in string userName, in string realName = null)
	{
		me = new IrcUser(nickName, userName, null, realName);
	}
	~this()
	{
		quit();
	}

	@property
	{
		/// The connected state of this client.
		bool connected() const
		{
			return _connected && socket.isAlive;
		}

		/// The maximum allowed nick name length on this server.
		/// If no explicit limit has been provided, this will be `0`.
		auto maxNickLength() const
		{
			return _maxNickLength;
		}

		/// Gets or sets the client's nick name for this network.
		/// Throws: `Exception` if length exceeds `maxNickLength` (if `maxNickLength` is > `0`).
		string nickName() const
		{
			return me.nickName;
		}
		/// ditto
		void nickName(in string value)
		{
			if (maxNickLength)
			{
				enforce(value.length <= maxNickLength, "Nick length exceeds max nick length enforced by server.");
			}

			me.nickName = value;

			if (_connected)
			{
				sendNick();
			}
		}

		/// Gets or sets the client's user name.
		/// Throws: `Exception` on attempted change while connected.
		string userName() const
		{
			return me.userName;
		}
		/// ditto
		void userName(in string value)
		{
			enforce(!_connected, "Cannot change userName while connected.");
			me.userName = value;
		}

		/// Gets the currently assigned host name.
		string hostName() const
		{
			return me.hostName;
		}

		/// Gets or sets the real name for this client.
		/// Throws: `Exception` on attempted change while connected.
		string realName() const
		{
			return me.realName;
		}
		/// ditto
		void realName(in string value)
		{
			enforce(!_connected, "Cannot change realName while connected.");
			me.realName = value;
		}

		/// Gets the name of the currently connected network.
		string networkName() const
		{
			return _networkName;
		}

		/// Gets the channel user modes supported by the currently connected network.
		/// Defaults to 'o', 'v'
		auto channelUserModes() const { return _channelUserModes; }
		/// Gets the user prefixes supported by the currently connected network.
		/// Defaults to '@', '+'
		auto channelUserPrefixes() const { return _channelUserPrefixes; }
	}

	/**
		Connects to the given address.

		Params:
			address = The address of the server to connect to.
			password = The password for this server (optional).

		Throws:
			`Exception` if already connected,
			if `nickName` is `null`,
			if `userName` is `null`,
			if `realName` is `null`.
	*/
	void connect(Address address, in string password = null)
	{
		enforce(!_connected, "Already connected.");
		enforceNotNull(nickName, nickName.stringof);
		enforceNotNull(userName, userName.stringof);
		enforceNotNull(realName, realName.stringof);

		socket = new TcpSocket();
		socket.connect(address);
		_connected = true;

		if (password != null)
		{
			raw(IrcCommand.Pass ~ ' ' ~ password);
		}

		sendNick();
		rawf(IrcCommand.User ~ " %s * * :%s", userName, realName);
	}

	/// Sends a formatted raw message.
	/// See_Also: raw
	void rawf(Args...)(in string fmt, Args args)
	{
		raw(format(fmt, args));
	}
	/// Sends a raw message.
	/// Throws: `Exception` if not connected or if the line is empty.
	/// See_Also: rawf
	void raw(in string line)
	{
		enforce(_connected, "Cannot send data on unconnected socket.");
		enforceNotNull(line, line.stringof);

		me.resetActionTime();
		lastNetTime = MonoTime.currTime;

		socket.send(line ~ "\r\n");
	}

	/**
		Sends a formatted message.
	
		Params:
			target = The target of the message.
			fmt    = Format string for the message.
			args   = Arguments for the format string.

		Throws:
			`Exception` if `target` is `null`.

		See_Also:
			send, sendMessage
	*/
	void sendf(Args...)(in string target, in string fmt, Args args)
	{
		send(target, format(fmt, args));
	}
	
	/**
		Sends a message.

		Params:
			target  = The target of the message.
			message = The message to be sent.

		Throws:
			`Exception` if `target` is `null`.

		See_Also:
			sendf, sendMessage
	*/
	void send(in string target, in string message)
	{
		enforceNotNull(target, target.stringof);
		sendMessage(IrcCommand.PrivMsg, target, message);
	}

	/**
		Sends a formatted notice.

		Params:
			target = The target of the notice.
			fmt    = Format string for the notice.
			args   = Arguments for the format string.

		Throws:
			`Exception` if `target` is `null`.

		See_Also:
			notice, sendMessage
	*/
	void noticef(Args...)(in string target, in string fmt, Args args)
	{
		notice(target, format(fmt, args));
	}

	/**
		Sends a notice.

		Params:
			target = The target of the notice.
			message = The message to be sent as a notice.

		Throws:
			`Exception` if `target` is `null`.

		See_Also:
			noticef, sendMessage
	*/
	void notice(in string target, in string message)
	{
		enforceNotNull(target, target.stringof);
		sendMessage(IrcCommand.Notice, target, message);
	}

	private void ctcp(in string command, in string target, in string tag, in string message)
	{
		enforceNotNull(target, target.stringof);

		string doFormat(in string tag, in string message)
		{
			if (message is null)
			{
				return format!("\x01%s\x01")(tag);
			}

			Appender!string result;
			result.put('\x01');
			result.put(tag);
			result.put(' ');
			result.put(message);

			if (!message.endsWith('\x01'))
			{
				result.put('\x01');
			}

			return result.data;
		}

		auto outbound = doFormat(tag, message);
		auto lineLength = LINE_LENGTH - format!("%s %s :")(command, target).length - 1;

		while (outbound.length > lineLength)
		{
			auto s = outbound[0 .. lineLength];
			const space = s.indexOf(' ');
			auto i = s.lastIndexOf(' ');

			if (i < 0 || i <= space)
			{
				i = lineLength;
			}
			else
			{
				s = s[0 .. i++];
			}

			sendMessage(command, target, s ~ '\x01');
			outbound = doFormat(tag, outbound[i .. $]);
		}

		sendMessage(command, target, outbound);
	}

	/**
		Sends a CTCP query to the specified target.

		Params:
			target  = The target to send the query to.
			tag     = The CTCP tag.
			message = Optional message.

		Throws:
			`Exception` if `target` is `null`.

		See_Also:
			ctcpReply
	*/
	void ctcpQuery(in string target, in string tag, in string message = null)
	{
		ctcp(IrcCommand.PrivMsg, target, tag, message);
	}

	/**
		Sends a CTCP reply to the specified target.

		Params:
			target  = The target to send the reply to.
			tag     = The CTCP tag.
			message = Optional message.

		Throws:
			`Exception` if `target` is `null`.

		See_Also:
			ctcpQuery
	*/
	void ctcpReply(in string target, in string tag, in string message = null)
	{
		ctcp(IrcCommand.Notice, target, tag, message);
	}

	/**
		Joins the specified channel.

		Params:
			channel = Channel to join.
			key     = Channel key (password, optional)

		Throws:
			`Exception` if `channel` is not a valid channel string.

		See_Also:
			isChannel
	*/
	void join(string channel, string key = null)
	{
		enforceChannel(channel);

		if (key is null)
		{
			raw(IrcCommand.Join ~ ' ' ~ channel);
		}
		else
		{
			raw(IrcCommand.Join ~ ' ' ~ channel ~ " :" ~ key);
		}
	}

	/**
		Parts (leaves) the specified channel.

		Params:
			channel = Channel to part.
			message = Part message (optional).
	*/
	void part(in string channel)
	{
		raw(IrcCommand.Part ~ ' ' ~ channel);
	}
	/// ditto
	void part(in string channel, in string message)
	{
		raw(IrcCommand.Part ~ ' ' ~ channel ~ " :" ~ message);
	}

	/// Quit the currently connected network.
	/// Params: message = Quit message (optional).
	void quit(in string message = null)
	{
		if (connected)
		{
			raw(IrcCommand.Quit ~ " :" ~ message);
		}

		disconnect();
	}

	/**
		Kicks a user from the specified channel.

		Params:
			channel = The channel to perform the kick in.
			user    = The user to kick.
			comment = Comment for the kick (optional).
	*/
	void kick(in string channel, IrcUser user, in string comment = null)
	{
		kick(channel, user.nickName, comment);
	}
	/// ditto
	void kick(in string channel, in string user, in string comment = null)
	{
		if (comment !is null)
		{
			raw(IrcCommand.Kick ~ ' ' ~ channel ~ ' ' ~ user ~ " :" ~ comment);
		}
		else
		{
			raw(IrcCommand.Kick ~ ' ' ~ channel ~ ' ' ~ user);
		}
	}

	/**
		Sets a mode on a target.

		Params:
			target = Target to set modes on.
			type = Type ('+' or '-').
			args = Mode arguments.
	*/
	void mode(in string target, char type, in string args)
	{
		enforce(type == '+' || type == '-', "type must b e either '+' or '-'.");
		rawf(IrcCommand.Mode ~ " %s %c%s", target, type, args);
	}

	// see: https://github.com/JakobOvrum/Dirk/blob/ec8acb2441fc0ec14b186971cc15ddcd170e5086/source/irc/client.d#L628
	/// Adds user modes to self.
	/// See_Also: mode, removeUserModes
	void addUserModes(in string modes)
	{
		mode(nickName, '+', modes);
	}
	/// Removes user modes from self.
	/// See_Also: mode, addUserModes
	void removeUserModes(in string modes)
	{
		mode(nickName, '-', modes);
	}

	/**
		Add modes to a channel.

		Params:
			channel = Channel whose modes are to be modified.
			modes   = The modes to add.
			args    = Arguments for the mode (optional).

		Throws:
			`Exception` if `channel` is not a valid channel string.

		See_Also:
			mode, removeChannelModes
	*/
	void addChannelModes(in string channel, in string modes, in string[] args = null)
	{
		if (args.empty)
		{
			mode(channel, '+', modes);
		}
		else
		{
			mode(channel, '+', modes ~ ' ' ~ args.join(' '));
		}
	}

	/**
		Removes modes from a channel.

		Params:
			channel = Channel whose modes are to be modified.
			modes   = The modes to remove.

		Throws:
			`Exception` if `channel` is not a valid channel string.

		See_Also:
			mode, addChannelModes
	*/
	void removeChannelModes(in string channel, in string modes)
	{
		mode(channel, '-', modes);
	}

	/**
		Adds arguments to a channel list. (e.g ban list).

		Params:
			channel = Channel whose list is to be modified.
			type = List type (e.g b for ban list).
			args = Arguments to add to the list.
		
		Throws:
			`Exception` if `channel` is not a valid channel string.

		See_Also:
			mode, ban
	*/
	void addToChannelList(in string channel, char type, in string[] args)
	{
		enforceChannel(channel);

		foreach (arg; args)
		{
			rawf(IrcCommand.Mode ~ " %s +%c %s", channel, type, arg);
		}
	}

	/**
		Removes arguments from a channel list. (e.g ban list).

		Params:
			channel = Channel whose list is to be modified.
			type = List type (e.g b for ban list).
			args = Arguments to remove from the list.
		
		Throws:
			`Exception` if `channel` is not a valid channel string.

		See_Also:
			mode, unban
	*/
	void removeFromChannelList(in string channel, char type, in string[] args)
	{
		enforceChannel(channel);

		foreach (arg; args)
		{
			rawf(IrcCommand.Mode ~ " %s -%c %s", channel, type, arg);
		}
	}

	/**
		Bans a user from the specified channel.

		Params:
			channel = The channel to ban from.
			user = The user to ban.

		Throws:
			`Exception` if `channel` is not a valid channel string.

		See_Also:
			unban, kick, kickBan
	*/
	void ban(in string channel, IrcUser user)
	{
		ban(channel, user.toString());
	}
	
	/**
		Bans a mask from the specified channel.

		Params:
			channel = The channel to ban from.
			mask    = The mask to ban.

		Throws:
			`Exception` if `channel` is not a valid channel string.

		See_Also:
			unban, kick, kickBan
	*/
	void ban(in string channel, in string mask)
	{
		enforceChannel(channel);
		addToChannelList(channel, 'b', [ mask ]);
	}

	/**
		Removes the specified mask from the channel ban list.

		Params:
			channel = The channel whose ban list is to be modified.
			mask = The mask to be removed.

		Throws:
			`Exception` if `channel` is not a valid channel string.
	*/
	void unban(in string channel, in string mask)
	{
		enforceChannel(channel);
		removeFromChannelList(channel, 'b', [ mask ]);
	}

	/**
		Kicks and bans a user from the specified channel.

		Params:
			channel = The channel to kick ban the user from.
			user    = The user to be kick banned.
			comment = Kick comment (optional).

		Throws:
			`Exception` if `channel` is not a valid channel string.
	*/
	void kickBan(in string channel, IrcUser user, in string comment = null)
	{
		kickBan(channel, user.nickName, comment);
	}
	
	/**
		Kicks and bans a user from the specified channel.

		Params:
			channel  = The channel to kick ban the user from.
			nickName = The nick name of the user to be kicked.
			comment  = Kick comment (optional).

		Throws:
			`Exception` if `channel` is not a valid channel string.
	*/
	void kickBan(in string channel, in string nickName, in string comment = null)
	{
		ban(channel, nickName);
		kick(channel, nickName, comment);
	}

	/// Perform a whois on the specified target.
	/// Fires the onWhois events on success.
	void whois(in string target)
	{
		raw(IrcCommand.Whois ~ ' ' ~ target);
	}

	/// Performs a who on the specified user and channel.
	void who(in string channel, in string user)
	{
		enforceChannel(channel);
		raw("WHO " ~ channel ~ ' ' ~ user);
	}

	/// Performs a who on the specified target.
	void who(in string target)
	{
		raw("WHO " ~ target);
	}

	/**
		Sends a message.
		It's recommended that you don't use this function directly.

		Params:
			command = Message command to send.
			target = Target of the message.
			message = Content of message.

		Throws:
			`Exception` if `target` or `message` is `null`.
	*/
	void sendMessage(in string command, in string target, in string message)
	{
		enforceNotNull(target, target.stringof);
		enforceNotNull(message, message.stringof);

		string doFormat(in string command, in string target, in string message)
		{
			return format!("%s %s :%s")(command, target, message);
		}

		auto outbound = doFormat(command, target, message);
		const colon = outbound.indexOf(':');

		while (outbound.length > LINE_LENGTH)
		{
			auto s = outbound[0 .. LINE_LENGTH];
			auto i = s.lastIndexOf(' ');

			if (i >= 0 && i > colon)
			{
				s = s[0 .. ++i];
			}
			else
			{
				i = LINE_LENGTH;
			}

			raw(s);
			outbound = doFormat(command, target, outbound[i .. $]);
		}

		raw(outbound);
	}

	/// Reads data from the server.
	/// Returns: `false` if the connection has been closed.
	bool read()
	{
		if (!_connected)
		{
			throw new Exception("Cannot receive data on unconnected socket.");
		}

		socket.blocking = false;

		char[] data;

		if (overflow !is null)
		{
			const remainder = (overflow.length > IRC_MAX_LEN) ? 0 : IRC_MAX_LEN - overflow.length;
			data = !remainder ? in_buffer : new char[remainder];
		}
		else
		{
			data = in_buffer;
		}

		ptrdiff_t received = socket.receive(data);
		const now = MonoTime.currTime;

		if (!received || received == Socket.ERROR)
		{
			if (wouldHaveBlocked())
			{
				socket.blocking = true;

				// If it has been 30 seconds since the last
				// received message, see if we should send a ping
				// and re-evaluate. Otherwise, connection is lost.
				if (now - lastNetTime >= seconds(30))
				{
					if (!timingOut)
					{
						timingOut = true;
						raw("PING 12345");
					}
					else
					{
						disconnect();
					}
				}

				return _connected;
			}

			if (overflow is null)
			{
				immutable text = socket.getErrorText().idup;
				disconnect();
				throw new Exception(text);
			}
		}

		char[] buffer = data[0 .. received];

		lastNetTime = now;
		timingOut = false;

		if (overflow !is null)
		{
			buffer = overflow ~ buffer;
			overflow = null;
		}

		string[] lines = buffer.splitter("\r\n")
		                       .filter!((x) => x.length > 0)
		                       .map!(to!string)
		                       .array;

		if (received > 0 && !buffer.endsWith("\r\n"))
		{
			auto i = buffer.lastIndexOf('\n');
			overflow = buffer[++i .. $].dup;
			lines = lines[0 .. $ - 1];
		}

		foreach (string s; lines)
		{
			debug stdout.writeln(s);
			string[] tags;
			string prefix, command;
			string[] args;

			string[] getArgs(in string str)
			{
				auto s = str.findSplit(" :");

				if (s[2].empty)
				{
					s = str.findSplit(":");
				}

				auto result = s[0].split(" ");
				return (s[2].length) ? result ~ s[2] : result;
			}

			// If the line starts with a colon, there aren't
			// any tags to deal with.
			if (s[0] == ':')
			{
				s = s[1 .. $];
				prefix = s.takeUntil!isWhite;
				s.takeWhile!isWhite;
			}
			else if (s[0] == '@')
			{
				s = s[1 .. $];
				Appender!string tags_str;
				ptrdiff_t colon;

				while (true)
				{
					auto r = s[colon .. $]; 
					colon = r.indexOf(':');
					enforce(colon >= 0, "Malformed line: " ~ s);
					
					if (r[colon - 1] == ' ')
					{
						tags_str.put(r[0 .. colon - 1]);
						r = r[++colon .. $];

						prefix = r.takeUntil!isWhite;
						r.takeWhile!isWhite;
						s = r;

						break;
					}
					else
					{
						tags_str.put(r[0 .. ++colon]);
					}
				}

				// TODO: un-escape tags
				tags = tags_str.data.split(';');
				debug stdout.writeln("TAGS: ", tags);
			}

			command = s.takeUntil!isWhite;
			s.takeWhile!isWhite;
			args = getArgs(s);

			parseCommand(tags, prefix, command, args);
		}

		socket.blocking = true;
		return _connected;
	}

	/// Get tracked user from nick name.
	/// Returns: `null` if user is not tracked.
	IrcUser getUser(in string nickName)
	{
		if (nickName == this.nickName)
		{
			return me;
		}

		auto search = find!((x) => !sicmp(x.nickName, nickName))(users[]);
		return search.empty ? null : search.front;
	}

	/**
		Begin tracking a user.

		Params:
			prefix = Prefix of the user to be tracked.
			channel = Channel the user is in (optional). This channel will also be tracked.

		Returns:
			Tracked `IrcUser`.
	*/
	IrcUser addUser(in string prefix, in string channel = null)
	{
		IrcUser result = getUser(getNickName(prefix));

		if (result is null)
		{
			result = IrcUser.fromPrefix(prefix);
			users.insert(result);
		}

		if (channel !is null)
		{
			channels[channel.idup].addUser(result);
		}

		return result;
	}

	/// Get a tracked user from a prefix.
	/// If a tracked user from this prefix doesn't exist, a new `IrcUser` is returned.
	/// Otherwise, the tracked user is returned.

	/**
		Get a tracked user from a prefix.

		Params:
			prefix = The prefix of the tracked user to search for.

		Returns:
			Existing `IrcUser` instance if already tracked, else a newly created instance.
	*/
	IrcUser getUserFromPrefix(in string prefix)
	{
		string nick = getNickName(prefix);
		IrcUser result = getUser(nick);

		if (result is null)
		{
			return IrcUser.fromPrefix(prefix);
		}
		else if (result.userName.empty || result.hostName.empty)
		{
			const u = IrcUser.fromPrefix(prefix);
			result.userName = u.userName;
			result.hostName = u.hostName;
		}

		return result;
	}

	/// Remove a tracked user.
	void removeUser(IrcUser user)
	{
		removeUser(user.nickName);
	}

	/// ditto
	void removeUser(in string nickName)
	{
		if (nickName == this.nickName)
		{
			return;
		}

		auto search = find!((x) => !sicmp(x.nickName, nickName))(users[]);

		if (!search.empty)
		{
			users.linearRemove(take(search, 1));
			channels.byValue().each!((x) => x.removeUser(nickName));
			debug stdout.writeln("Stopped tracking user: ", nickName);
		}
	}

	/// Remove a tracked user from a tracked channel.
	void removeChannelUser(in string channel, in string nickName)
	{
		auto u = getUser(nickName);

		if (u is null)
		{
			return;
		}

		if (u.channels.empty || (u.channels.length == 1 && !sicmp(u.channels[0], channel)))
		{
			removeUser(nickName);
		}
		else
		{
			channels[channel].removeUser(nickName);
		}
	}

	/// Remove a tracked channel.
	void removeChannel(in string channel)
	{
		enforceChannel(channel);
		auto chan = channel in channels;
		enforce(chan !is null, "Channel isn't tracked.");

		foreach (IrcUser user; chan.users)
		{
			chan.removeUser(user.nickName);

			if (user.channels.empty)
			{
				removeUser(user);
			}
		}

		channels.remove(channel);
	}

	/// Raised on successful connect to the server.
	void delegate()[] onConnect;

	/**
		Raised when the client receives a CTCP query.

		Params:
			user   = The user who sent the CTCP query.
			source = The location it was sent from (e.g a channel).
			tag    = The CTCP tag (e.g PING, VERSION)
			data   = Additional data sent qith the CTCP query.
	*/
	void delegate(IrcUser user, in string source, in string tag, in string data)[] onCtcpQuery;

	/**
		Raised when a response to a CTCP query is received.

		Params:
			user   = The user who sent the CTCP reply.
			source = The location it was sent from (e.g a channel).
			tag    = The CTCP tag (e.g PING, VERSION)
			data   = Additional data sent qith the CTCP reply.
	*/
	void delegate(IrcUser user, in string source, in string tag, in string data)[] onCtcpReply;

	/**
		Raised when a channel invite is received.
		Note that this is raised for ALL invites.
		When your client is invited, `target` will
		equal `nickName`.

		Params:
			user    = The user who issued the invite.
			target  = The user being invited.
			channel = The channel `target` has been invited to.
	*/
	void delegate(IrcUser user, in string target, in string channel)[] onInvite;

	/**
		Raised when a user joins a channel.

		Params:
			user    = The user who joined.
			channel = The channel the user joined.

		See_Also:
			onJoinTooSoon, onSuccessfulJoin
	*/
	void delegate(IrcUser user, in string channel)[] onJoin;

	/**
		Raised when this client joins a channel which
		has a join timer that has not yet finished.

		Params:
			user    = The user who joined (this client).
			channel = The channel joined.

		See_Also:
			onJoin, onSuccessfulJoin
	*/
	void delegate(in string channel, int seconds)[] onJoinTooSoon;

	/**
		Raised when this client has joined a channel.

		Params:
			channel = The channel joined.

		See_Also:
			onJoin, onJoinTooSoon
	*/
	void delegate(in string channel)[] onSuccessfulJoin;

	/**
		Raised when a user is kicked from a channel.

		Params:
			kicker     = The user who issued the kick.
			channel    = The channel the user is being kicked from.
			kickedNick = The user who is being kicked.
			comment    = Kick message.
	*/
	void delegate(IrcUser kicker, in string channel, in string kickedNick, in string comment)[] onKick;
	
	/**
		Raised when a channel or private message is received.

		Params:
			user    = The user that sent the message.
			target  = The target location. This can be a channel or a nickname (`nickName`).
			message = The content of the message.
	*/
	void delegate(IrcUser user, in string target, in string message)[] onMessage;

	/**
		Raised when a channel or user mode (or both) is changed.

		Params:
			user   = The user who set the mode.
			target = The target whose modes are to be changed. This can be a user or a channel.
			modes  = The modes to give/take.
			args   = The arguments for `modes`, if any.
	*/
	void delegate(IrcUser user, in string target, in string modes, in string[] args)[] onMode;
	
	/**
		Raised when the server MOTD begins.

		Params:
			message = The MOTD welcome message.

		See_Also:
			onMotdLine, onMotdEnd
	*/
	void delegate(in string message)[] onMotdStart;

	/**
		Raised for each line of the server MOTD.
		Let's be honest. It's probably just ASCII art.

		Params:
			line = The MOTD line.

		See_Also:
			onMotdStart, onMotdEnd
	*/
	void delegate(in string line)[] onMotdLine;

	/**
		Raised when the server MOTD begins.

		Params:
			message = The MOTD footer message.

		See_Also:
			onMotdStart, onMotdLine
	*/
	void delegate(in string message)[] onMotdEnd;

	/**
		Raised when a nick name list is received for a channel.

		Params:
			channel   = The channel containing the nick names.
			nickNames = The list of nick names.

		See_Also:
			onNameListEnd
	*/
	void delegate(in string channel, in string[] nickNames)[] onNameList;

	/**
		Raised when a nick name list received by `onNameList` has finished.

		Params:
			channel = The channel containing the nick names.

		See_Also:
			onNameListEnd
	*/
	void delegate(in string channel)[] onNameListEnd;

	/**
		Raised when a user's nick name has changed.

		Params:
			user    = The user whose nick name has changed.
			newNick = The user's new nick name.
	*/
	void delegate(IrcUser user, in string newNick)[] onNickChange;

	/**
		Raised when this client's nick name is in use.
		If the event is not handled by any delegates,
		an exception is thrown.

		To handle the exception, you must set a new name
		by changing `nickName`, and then return `true`.

		Params:
			oldNick = The nick name that is already in use.

		Returns:
			`true` if it has been handled, else `false`.
			If the event is not handled by any delegates,
			an exception is thrown.

		See_Also:
			nickName
	*/
	bool delegate(in string oldNick)[] onNickInUse;

	/**
		Raised when a notice is received.

		Params:
			user    = The user who issued the notice.
			target  = The target location for the notice. This can be a user or a channel.
			message = The content of the notice.
	*/
	void delegate(IrcUser user, in string target, in string message)[] onNotice;

	/**
		Raised when a user leaves a channel.
		This event is also raised when this client instance
		leaves a channel.

		Params:
			user    = The user who left.
			channel = The channel that the user left.

		See_Also:
			onQuit
	*/
	void delegate(IrcUser user, in string channel)[] onPart;

	/**
		Raised when a user leaves a channel.
		This event is only raised for users other than this instance.

		Params:
			user    = The user who quit.
			comment = The quit message.

		See_Also:
			onPart
	*/
	void delegate(IrcUser user, in string comment)[] onQuit;

	/**
		Provides the channel topic after successfully joining.

		Params:
			channel = The channel this topic belongs to.
			topic   = The topic.

		See_Also:
			onTopicInfo, onTopicChange
	*/
	void delegate(in string channel, in string topic)[] onTopic;

	/**
		Raised when a channel's topic has been changed.

		Params:
			user    = The user who changed the topic.
			channel = The channel this topic belongs to.
			topic   = The new topic.

		See_Also:
			onTopic, onTopicInfo
	*/
	void delegate(IrcUser user, in string channel, in string topic)[] onTopicChange;

	/**
		Metadata for the channel's topic.

		Params:
			channel = The channel this topic belongs to.
			nick    = The nick name of the user who last set the topic.
			time    = The time the topic was last set.

		See_Also:
			onTopic, onTopicChange
	*/
	void delegate(in string channel, in string nick, in string time)[] onTopicInfo;

	// TODO
	//void delegate(in IrcUser[] users)[] onUserhostReply;

	/**
		Raised for the account line of a WHOIS reply.

		Params:
			nick        = The nick name of the user.
			accountName = The account name of the user.
	*/
	void delegate(in string nick, in string accountName)[] onWhoisAccountReply;

	/**
		Raised for the channels line of a WHOIS reply.

		Params:
			nick     = The nick name of the user.
			channels = The channels this user is in.
	*/
	void delegate(in string nick, in string[] channels)[] onWhoisChannelsReply;

	/**
		Raised when the WHOIS reply is complete.

		Params:
			nick = The nick name of the user.
	*/
	void delegate(in string nick)[] onWhoisEnd;

	/**
		Raised for the idle line of a WHOIS reply.

		Params:
			nick     = The nick name of the user.
			idleTime = The amount of time the user has been idle.
	*/
	void delegate(in string nick, int idleTime)[] onWhoisIdleReply;

	/**
		Raised for the OPER line of a WHOIS reply.
		This only occurs if the user is an IRC operator.

		Params:
			nick = The nick name of the user.
	*/
	void delegate(in string nick)[] onWhoisOperatorReply;

	/**
		Raised for the user info line of a WHOIS reply.

		Params:
			userInfo = The info for the user (hostmask, etc).
	*/
	void delegate(IrcUser userInfo)[] onWhoisReply;

	/**
		Raised for the server line of a WHOIS reply.

		Params:
			nick           = The nick name of the user.
			serverHostName = The hostname of the server the user is connecting from.
			serverInfo     = Additional server information.
	*/
	void delegate(in string nick, in string serverHostName, in string serverInfo)[] onWhoisServerReply;

private:
	void disconnect()
	{
		socket.shutdown(SocketShutdown.BOTH);
		socket.close();
		_connected = false;
		timingOut = false;

		channels.clear();
		users.clear();
		overflow = null;
		me.hostName = null;
	}

	static void raiseCtcpEvent(typeof(onCtcpQuery) event, IrcUser user, in string target, in string message)
	{
		auto start = message.indexOf("\x01");
		auto end = message[start + 1 .. $].indexOf("\x01");
		string m = message[++start .. ++end];
		string tag = m.takeUntil!isWhite;
		m.takeWhile!isWhite;
		raiseEvent(event, user, target, tag, m);
	}

	void parseCommand(in string[] tags, in string prefix, in string command, in string[] args)
	{
		with (IrcCommand) switch (command)
		{
			default:
				debug stdout.writefln("Unhandled type %s: %s", command, args.join(' '));
				break;

				// ignored
			case RPL_YOURHOST:
			case RPL_CREATED:
			case RPL_MYINFO:
			case RPL_LUSERCLIENT:
			case RPL_LUSERCHANNELS:
			case RPL_LUSERME:
			case RPL_ENDOFWHO:
			case "042": // unique ID
			case "265": // Current Local Users
			case "266": // Current Global Users
				break;

			case Error:
				throw new Exception(args[0]);

			case Ping:
				raw("PONG :" ~ args[0]);
				break;

			case Pong:
				break;

			case Mode:
				IrcUser user = getUserFromPrefix(prefix);
				auto nicks = args.length > 2 ? args[2 .. $] : null;

				if (nicks !is null)
				{
					nicks = nicks.filter!((x) => !x.empty).array;
				}

				user.resetActionTime();
				raiseEvent(onMode, user, args[0], args[1], nicks);

				if (args[0].isChannel)
				{
					const channel = args[0];
					channels[channel].onMode(channel, args[1], nicks);
				}
				break;

			case ERR_NICKNAMEINUSE:
				void failed433()
				{
					disconnect();
					throw new Exception(`"433 Nick already in use" was unhandled`);
				}

				auto failedNick = args[1];
				bool handled = false;

				foreach(cb; onNickInUse)
				{
					try
					{
						handled = cb(failedNick);

						if (handled)
						{
							break;
						}
					}
					catch(Exception e)
					{
						failed433();
					}
				}

				if (!handled)
				{
					failed433();
				}

				break;

			case PrivMsg:
				auto target = args[0];
				IrcUser user = getUserFromPrefix(prefix);
				auto message = args[1];
				user.resetActionTime();

				if (isCtcp(message))
				{
					raiseCtcpEvent(onCtcpQuery, user, target, message);
				}
				else
				{
					raiseEvent(onMessage, user, target, message);
				}

				break;

			case Notice:
				auto target = args[0];
				IrcUser user = getUserFromPrefix(prefix);
				auto message = args[1];
				user.resetActionTime();

				if (isCtcp(message))
				{
					raiseCtcpEvent(onCtcpReply, user, target, message);
				}
				else
				{
					raiseEvent(onNotice, user, target, message);
				}

				break;

			case RPL_WELCOME:
				raiseEvent(onConnect);
				break;

			case RPL_MOTDSTART:
				raiseEvent(onMotdStart, args[1]);
				break;

			case RPL_MOTD:
				raiseEvent(onMotdLine, args[1]);
				break;

			case RPL_ENDOFMOTD:
				raiseEvent(onMotdEnd, args[1]);
				break;

			case DisplayedHost:
				me.hostName = args[1];
				break;

			case Nick:
				IrcUser user = getUserFromPrefix(prefix);
				auto newNick = args[0];
				user.resetActionTime();
				raiseEvent(onNickChange, user, newNick);

				// rename user in all channels where user is present
				channels.byValue()
					.filter!((x) => user.channels.canFind(x.name))
					.each!((x) => x.renameUser(user.nickName, newNick));

				user.nickName = newNick;
				break;

			case Join:
				if (!sicmp(getNickName(prefix), nickName))
				{
					auto channel = args[0];
					channels[channel] = new IrcChannel(channel, this);
					addUser(prefix, channel).resetActionTime();
					raiseEvent(onSuccessfulJoin, channel);
				}
				else
				{
					raiseEvent(onJoin, addUser(prefix, args[0]), args[0]);
				}

				break;

			case Invite:
				raiseEvent(onInvite, getUserFromPrefix(prefix), args[0], args[1]);
				break;

			case RPL_NAMREPLY:
				auto channel = args[2];
				auto names = args[3].split.filter!((x) => x.length > 0);

				foreach (string s; names)
				{
					auto nick = s;
					auto modes = nick.takeWhile!((x) => channelUserPrefixes.canFind(x));

					if (sicmp(nick, nickName) != 0) // skip self; added on join.
					{
						addUser(nick, channel);
					}

					if (!modes.empty)
					{
						channels[channel].setMode(nick, modes[0]);
					}
				}

				raiseEvent(onNameList, channel, names.array);
				break;

			case RPL_ENDOFNAMES:
				who(args[1]);
				raiseEvent(onNameListEnd, args[1]);
				break;

			case RPL_WHOREPLY:
				// [0:target] [1:channel] [2:user] [3:host] [4:server] [5:nick] [6:H/G/whatever not important] [7:[hop count] [real name]]
				IrcUser user = getUser(args[5]);

				if (user !is null)
				{
					auto rname = args[7].idup;
					rname.takeWhile!((x) => isDigit(x) || isWhite(x));

					user.userName = args[2];
					user.hostName = args[3];
					user.realName = rname;

					auto mode = args[6].idup;
					mode.takeUntil!((x) => channelUserPrefixes.canFind(x));

					if (!mode.empty)
					{
						channels[args[1]].setMode(user.nickName, mode[0]);
					}
				}
				break;

			case Part:
				IrcUser user = getUserFromPrefix(prefix);
				auto channel = args[0];

				raiseEvent(onPart, user, channel);

				if (!sicmp(user.nickName, nickName))
				{
					removeChannel(channel);
				}
				else
				{
					removeChannelUser(channel, user.nickName);
				}
				break;

			case Kick:
				IrcUser user = getUserFromPrefix(prefix);
				auto channel = args[0];
				auto kicked = args[1];
				string reason = args.length > 2 ? args[2] : "";

				user.resetActionTime();
				raiseEvent(onKick, user, channel, kicked, reason);

				if (!sicmp(kicked, nickName))
				{
					removeChannel(channel);
				}
				else
				{
					removeChannelUser(channel, kicked);
				}
				break;

			case Quit:
				IrcUser user = getUserFromPrefix(prefix);
				string message = args.empty ? null : args[0];

				raiseEvent(onQuit, user, message);
				removeUser(user);
				break;

			case RPL_TOPIC:
				raiseEvent(onTopic, args[1], args[2]);
				break;

			case TopicChange:
				raiseEvent(onTopicChange, getUserFromPrefix(prefix), args[0], args[1]);
				break;

			case TopicInfo:
				raiseEvent(onTopicInfo, args[1], args[2], args[3]);
				break;

			case RPL_WHOISUSER:
				IrcUser user = getUser(args[1]);

				if (user is null)
				{
					user = new IrcUser(args[1], args[2], args[3], args[5]);
				}
				else
				{
					user.nickName = args[1];
					user.userName = args[2];
					user.hostName = args[3];
					user.realName = args[5];
				}

				raiseEvent(onWhoisReply, user);
				break;

			case RPL_WHOISSERVER:
				raiseEvent(onWhoisServerReply, args[1], args[2], args[3]);
				break;

			case RPL_WHOISOPERATOR:
				raiseEvent(onWhoisOperatorReply, args[1]);
				break;

			case RPL_WHOISIDLE:
				raiseEvent(onWhoisIdleReply, args[1], to!int(args[2]));
				break;

			case RPL_WHOISCHANNELS:
				string nick = args[1];
				auto chanList = split(args[2]);

				foreach(ref channel; chanList)
				{
					char p = IrcChannel.noMode;

					while (channelUserPrefixes.canFind(channel[0]))
					{
						if (p == IrcChannel.noMode || channelUserPrefixes.indexOf(channel[0]) < channelUserPrefixes.indexOf(p))
						{
							p = channel[0];
						}

						channel = channel[1 .. $];
					}

					if (p == IrcChannel.noMode)
					{
						continue;
					}

					auto chan = channel in channels;

					if (chan !is null)
					{
						chan.setMode(nick, p);
					}
				}

				raiseEvent(onWhoisChannelsReply, nick, chanList);
				break;

			case RPL_ENDOFWHOIS:
				raiseEvent(onWhoisEnd, args[1]);
				break;

			case u_307:
				if (!sicmp(args[0], nickName))
				{
					raiseEvent(onWhoisAccountReply, args[1], args[1]);
				}
				break;

			case RPL_WHOISACCOUNT:
				raiseEvent(onWhoisAccountReply, args[1], args[2]);
				break;

			case RPL_USERHOST: // TODO: onUserhostReply
				break;

			case "005":
				const(string)[] trimmed = args[1 .. $ - 1];

				foreach (s; trimmed)
				{
					auto separator = s.indexOf('=');
					string key, value;

					if (separator == -1)
					{
						key = s;
					}
					else
					{
						key = s[0 .. separator];
						value = s[++separator .. $];
					}

					switch (key)
					{
						default:
							break;

						case "PREFIX":
							if (value.empty)
							{
								break;
							}

							enforce(value[0] == '(');

							auto end = value.indexOf(')');
							enforce(end != -1 && end != value.length - 1);

							string modes = value[1 .. end];
							string prefixes = value[end + 1 .. $];
							enforce(modes.length == prefixes.length);

							_channelUserModes    = modes.dup;
							_channelUserPrefixes = prefixes.dup;
							break;

						case "CHANMODES":
							if (value.empty)
							{
								break;
							}

							string[4] modeTypes;

							modeTypes = value.split(',');

							if (channelListModes != modeTypes[0])
							{
								channelListModes = modeTypes[0];
							}

							if (channelParameterizedModes != modeTypes[1])
							{
								channelParameterizedModes = modeTypes[1];
							}

							if (channelNullaryRemovableModes != modeTypes[2])
							{
								channelNullaryRemovableModes = modeTypes[2];
							}

							if (channelSettingModes != modeTypes[3])
							{
								channelSettingModes = modeTypes[3];
							}
							break;

						case "NICKLEN":
							if (!value.empty)
							{
								_maxNickLength = to!(typeof(_maxNickLength))(value);
							}

							break;

						case "NETWORK":
							if (!value.empty)
							{
								_networkName = value;
							}

							break;
					}
				}

				break;

				//[1] = {length=5 "#test"}
				//[2] = {length=57 "You must wait 5 seconds after being kicked to rejoin (+J)"}
			case JoinTooSoon:
				string whatever = args[2];
				whatever.takeUntil!isDigit;

				enforce(!whatever.empty);
				
				string seconds_str = whatever.takeWhile!isDigit;
				whatever.takeWhile!isWhite;
				
				const seconds = to!int(seconds_str);

				if (whatever.startsWith("second"))
				{
					raiseEvent(onJoinTooSoon, args[1], seconds);
				}
				break;
		}
	}

	static void raiseEvent(E, A...)(E[] event, A args)
	{
		event.each!((x) => x(args));
	}

	static bool isCtcp(in string message)
	{
		auto m = matchAll(message, ctcpRegex);
		return !m.empty;
	}
}

// TODO: Name consistency
/// Supported IRC commands.
enum IrcCommand : string
{
	ChanModes         = "CHANMODES",
	Mode              = "MODE",
	Error             = "ERROR",
	Join              = "JOIN",
	Invite            = "INVITE",
	Kick              = "KICK",
	Network           = "NETWORK",
	Nick              = "NICK",
	NickLen           = "NICKLEN",
	Notice            = "NOTICE",
	Part              = "PART",
	Pass              = "PASS",
	Ping              = "PING",
	Pong              = "PONG",
	Prefix            = "PREFIX",
	PrivMsg           = "PRIVMSG",
	Quit              = "QUIT",
	User              = "USER",
	Whois             = "WHOIS",
	TopicChange       = "TOPIC",
	RPL_WELCOME       = "001",
	RPL_YOURHOST      = "002",
	RPL_CREATED       = "003",
	RPL_MYINFO        = "004",
	RPL_BOUNCE        = "005",
	RPL_LUSERCLIENT   = "251",
	RPL_LUSERCHANNELS = "254",
	RPL_LUSERME       = "255",
	RPL_USERHOST      = "302",
	u_307             = "307",
	RPL_WHOISUSER     = "311",
	RPL_WHOISSERVER   = "312",
	RPL_WHOISOPERATOR = "313",
	RPL_ENDOFWHO      = "315",
	RPL_WHOISIDLE     = "317",
	RPL_ENDOFWHOIS    = "318",
	RPL_WHOISCHANNELS = "319",
	RPL_WHOISACCOUNT  = "330",
	RPL_TOPIC         = "332",
	TopicInfo         = "333",
	RPL_WHOREPLY      = "352",
	RPL_NAMREPLY      = "353",
	RPL_ENDOFNAMES    = "366",
	RPL_MOTD          = "372",
	RPL_MOTDSTART     = "375",
	RPL_ENDOFMOTD     = "376",
	DisplayedHost     = "396",
	ERR_NICKNAMEINUSE = "433",
	JoinTooSoon       = "495"
}
