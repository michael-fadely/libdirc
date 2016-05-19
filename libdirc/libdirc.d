module libdirc;

import core.time;
import std.algorithm;
import std.array;
import std.container.slist;
import std.conv;
import std.exception : enforce;
import std.range;
import std.regex;
import std.string;
import std.uni : sicmp;

public import std.socket;

debug import std.stdio;

// https://github.com/JakobOvrum/Dirk/blob/ec8acb2441fc0ec14b186971cc15ddcd170e5086/source/irc/protocol.d#L13-L20
private enum IRC_MAX_LEN      = 512;
private enum IRC_USERHOST_LEN = 63 + 10 + 1;
private enum LINE_LENGTH      = (IRC_MAX_LEN - "\r\n".length) - IRC_USERHOST_LEN;

private auto ctcpRegex = ctRegex!(`\x01[^\x01]+\x01`);

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

/// Checks the first character of the given string for '#'.
bool isChannel(in string str)
{
	return !str.empty && str[0] == '#';
}

/// Returns the nick name portion of a user prefix.
string getNickName(in string prefix)
{
	string result = prefix.idup;
	return result.munch("^! ");
}

/// Convenience function for enforcing `str.isChannel`
void enforceChannel(string str)
{
	enforce(str.isChannel, "Input string is not a valid channel string.");
}

/// Convenience function for enforcing non-null parameters.
void enforceNotNull(string str, string name)
{
	enforce(!str.empty, name ~ " must not be empty.");
}

/**
	Represents a user on an IRC Network.

	See_Also:
		IrcChannel, IrcClient
*/
class IrcUser
{
private:
	string[] _channels;
	MonoTime _lastActionTime;

	string _nickName, _userName, _hostName, _realName;

public:
	/**
		Constructs an `IrcUser`

		Params:
			nickName = The nick name of this user.
			userName = The user name of this user (optional).
			hostName = The host name of this user (optional).
			realName = The "real name" of this user (optional).

		Throws:
			`Exception` if nickName is `null`.
	*/
	this(in string nickName, in string userName = null, in string hostName = null, in string realName = null)
	{
		enforceNotNull(nickName, nickName.stringof);
		this.nickName = nickName;

		if (userName !is null)
		{
			this.userName = userName;
		}

		if (hostName !is null)
		{
			this.hostName = hostName;
		}

		if (realName !is null)
		{
			this.realName = realName;
		}
	}

	@property
	{
		/// Gets or sets the nick name for this user.
		/// Note that the setter duplicates your input.
		auto nickName() const
		{
			return _nickName;
		}
		/// ditto
		void nickName(in string value)
		{
			_nickName = value.dup;
		}

		/// Gets or sets the user name for this user.
		/// Note that the setter duplicates your input.
		auto userName() const
		{
			return _userName;
		}
		/// ditto
		void userName(in string value)
		{
			_userName = value.dup;
		}

		/// Gets or sets the host name for this user.
		/// Note that the setter duplicates your input.
		auto hostName() const
		{
			return _hostName;
		}
		/// ditto
		void hostName(in string value)
		{
			_hostName = value.dup;
		}

		/// Gets or sets the "real name" for this user.
		/// Note that the setter duplicates your input.
		auto realName() const
		{
			return _realName;
		}
		/// ditto
		void realName(in string value)
		{
			_realName = value.dup;
		}

		/// Returns an array of channels this user is associated with.
		auto channels() { return _channels; }
		/// Returns the time of the last recorded action performed by this user.
		/// See_Also: resetActionTime, isIdle, idleTime
		auto lastActionTime() { return _lastActionTime; }
	}

	/// Resets the last recorded action time.
	/// See_Also: lastActionTime
	void resetActionTime()
	{
		_lastActionTime = MonoTime.currTime();
	}

	/**
		Returns the idle state of this user.

		Params:
			current = Current time.
			d = Minimum elapsed idle threshold.
	*/
	bool isIdle(in MonoTime current, in Duration d)
	{
		return current - _lastActionTime >= d;
	}

	/// Returns the duration for which this user has been idle.
	/// See_Also: isIdle, lastactionTime, resetActionTime
	Duration idleTime()
	{
		return MonoTime.currTime() - _lastActionTime;
	}

	/// Converts this user to a prefix string.
	/// See_Also: fromPrefix
	override string toString() const
	{
		return format("%s!%s@%s", _nickName, _userName, _hostName);
	}

	// see: https://github.com/JakobOvrum/Dirk/blob/master/source/irc/protocol.d#L235
	/// Constructs an `IrcUser` from a prefix string.
	static IrcUser fromPrefix(string prefix)
	{
		IrcUser result;

		if (prefix !is null)
		{
			string nickName, userName, hostName;

			nickName = prefix.munch("^!").dup;

			if (prefix.length)
			{
				prefix = prefix[1 .. $];
				userName = prefix.munch("^@");

				if (prefix.length)
				{
					hostName = prefix[1 .. $];
				}
			}

			result = new IrcUser(nickName, userName, hostName);
		}

		return result;
	}

	@safe unittest
	{
		const user = new IrcUser("nick", "user", "host");
		assert(user.toString == "nick!user@host");

		const prefix = IrcUser.fromPrefix("nick!user@host");
		assert(prefix.nickName == "nick");
		assert(prefix.userName == "user");
		assert(prefix.hostName == "host");
		assert(prefix.toString == "nick!user@host");

		const notUser = IrcUser.fromPrefix("irc.server.net");
		assert(notUser.nickName == "irc.server.net");
	}
}

/// Represents an IRC channel.
class IrcChannel
{
private:
	string _name;
	SList!IrcUser _users;
	char[string] _userModes;
	IrcClient _parent;

public:
	/**
		Constructs an `IrcChannel`.

		Params:
			name = `string` representation of the channel.
			parent = Parent client.

		See_Also:
			IrcUser, IrcClient
	*/
	this(in string name, IrcClient parent)
	{
		_name = name;
		_parent = parent;
	}

	/// Used when no mode is associated with a user.
	static const char noMode = '\0';

	@property
	{
		/// Gets the name of this channel.
		auto name() const { return _name; }
		/// Gets the tracked user modes for all tracked users in this channel.
		auto userModes() const { return _userModes; }
		/// Gets all tracked users for this channel.
		auto users() { return _users; }
	}

	/**
		Get a tracked user by nick name.

		Returns:
			the tracked user if found, else `null`.
	*/
	IrcUser getUser(in string nickName)
	{
		auto search = find!(x => !sicmp(x.nickName, nickName))(_users[]);
		return search.empty ? null : search.front;
	}

	/// Stops tracking a user in this channel.
	void removeUser(in string nickName)
	{
		if (_userModes.remove(nickName))
		{
			debug stdout.writefln("Removed user modes for %s in %s", nickName, name);
		}

		auto search = find!(x => !sicmp(x.nickName, nickName))(_users[]);
		if (search.empty)
		{
			return;
		}

		_users.linearRemove(take(search, 1));
		debug stdout.writefln("Removed user %s from %s", nickName, name);
		auto u = search.front;

		const l = u._channels.length;
		u._channels = u._channels.remove!(x => x == name);
		if (l > u._channels.length)
		{
			debug stdout.writefln("Removed channel association for %s in %s", nickName, name);
		}
	}

	/// Begins tracking a user in this channel.
	void addUser(IrcUser user)
	{
		user._channels ~= name;
		_users.insert(user);
	}
	/// ditto
	void addUser(in string nickName)
	{
		auto user = _parent.getUser(nickName);
		if (user !is null)
		{
			addUser(user);
		}
	}

	// TODO: private
	/**
		Changes the nick name of a tracked user in this channel.
		It's not recommended that you call this function directly.

		Params:
			oldNick = The current nick name of the user.
			newNick = The new nick name of the user.
	*/
	void renameUser(in string oldNick, in string newNick)
	{
		auto mode = getMode(oldNick);
		if (mode != noMode)
		{
			setMode(newNick, mode);
			_userModes.remove(oldNick);
		}
	}

	/**
		Get the channel mode of a tracked user.
		Returns:
			The user mode character if the user is tracked.
			Otherwise, `IrcChannel.noMode`.
	*/
	char getMode(in IrcUser user)
	{
		return getMode(user.nickName);
	}
	/// ditto
	char getMode(in string nickName)
	{
		auto m = nickName in _userModes;
		return m is null ? noMode : *m;
	}

	// TODO: private
	/**
		Sets the channel mode of a tracked user.
		It's not recommended that you call this function directly.

		Params:
			nickName = The user whose mode is to be set.
			mode = The mode to set.
	*/
	void setMode(in string nickName, char mode)
	{
		if (_parent.channelUserPrefixes.canFind(mode))
		{
			_userModes[nickName.idup] = mode;
		}
	}

	// TODO: distinguish add/remove "modes" ('+', '-') from actual modes ('v', 'o', 'b')
	/**
		Used internally to manage the modes of tracked users.

		It's not recommended that you call this function directly.
		It is made available in the event that you need to extend
		functionality in some way.

		Params:
			target = The target channel.
			modes  = The modes use (+, -, etc)
			args   = The actual modes to set.
	*/
	void onMode(in string target, in string modes, in string[] args)
	{
		if (!target.isChannel || target != name || args.empty)
		{
			return;
		}

		enum modeMode
		{
			None,
			Give,
			Take
		}

		modeMode m;
		size_t i;
		IrcUser u;

		foreach (char c; modes)
		{
			switch (c)
			{
				case '+':
					m = modeMode.Give;
					continue;
				case '-':
					m = modeMode.Take;
					continue;
				default:
					break;
			}

			auto index = _parent.channelUserModes.indexOf(c);
			if (index > -1)
			{
				if (u is null || u.nickName != args[i])
				{
					u = getUser(args[i]);
					// This happened once, and I can't track it down. Needs debugging at some point.
					if (u is null)
					{
						//throw new Exception("Cannot handle modes on users not in this channel!");
						++i;
						continue;
					}
				}

				with (modeMode) switch(m)
				{
					default:
						throw new Exception("Cannot deduce mode type - was not Give or Take!");

					case Give:
						auto current = getMode(u.nickName);

						if (current != IrcChannel.noMode)
						{
							const current_index = _parent.channelUserPrefixes.indexOf(current);
							if (index >= current_index)
								break;
						}

						_userModes[u.nickName.idup] = _parent.channelUserPrefixes[index];
						break;

					case Take:
						_userModes.remove(u.nickName);
						_parent.whois(u.nickName);
						break;
				}
			}

			++i;
		}
	}
}

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
	string channelListModes             = "b";  // Type A
	string channelParameterizedModes    = null; // Type B
	string channelNullaryRemovableModes = null; // Type C
	string channelSettingModes          = null; // Type D

	uint maxNickLength;

	IrcUser me;

	string _networkName;

	private void sendNick()
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
		if (_connected)
			quit();
	}

	@property
	{
		/// The connected state of this client.
		bool connected() const
		{
			return _connected && socket.isAlive;
		}

		/// Gets or sets the client's nick name for this network.
		auto nickName() const
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

			me.nickName = value.idup;
			if (_connected)
			{
				sendNick();
			}
		}

		/// Gets or sets the client's user name.
		/// Throws: `Exception` on attempted change while connected.
		auto userName() const
		{
			return me.userName;
		}
		/// ditto
		void userName(in string value)
		{
			enforce(!_connected, "Cannot change userName while connected.");
			me.userName = value.idup;
		}

		/// Gets the currently assigned host name.
		auto hostName() const
		{
			return me.hostName;
		}

		/// Gets or sets the real name for this client.
		/// Throws: `Exception` on attempted change while connected.
		auto realName() const
		{
			return me.realName;
		}
		/// ditto
		void realName(in string value)
		{
			enforce(!_connected, "Cannot change realName while connected.");
			me.realName = value.idup;
		}

		/// Gets the name of the currently connected network.
		auto networkName() const
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
			if nickName is `null`,
			if userName is `null`,
			if realName is `null`.
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
		rawf("%s %s * * :%s", IrcCommand.User, userName, realName);
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
				return format("\x01%s\x01", tag);
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
		auto lineLength = LINE_LENGTH - format("%s %s :", command, target).length - 1;

		while (outbound.length > lineLength)
		{
			auto s = outbound[0 .. lineLength];
			auto space = s.indexOf(' ');
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
	/// ditto
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
	/// ditto
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
			return format("%s %s :%s", command, target, message);
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
			auto remainder = IRC_MAX_LEN - overflow.length;
			data = !remainder ? in_buffer : new char[remainder];
		}
		else
		{
			data = in_buffer;
		}

		ptrdiff_t received = socket.receive(data);
		auto now = MonoTime.currTime;

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

		// see: https://github.com/JakobOvrum/Dirk/blob/master/source/irc/protocol.d#L78
		auto buffer = cast(string)data[0 .. received];

		lastNetTime = now;
		timingOut = false;

		if (overflow !is null)
		{
			buffer = cast(string)overflow ~ buffer;
			overflow = null;
		}

		auto lines = buffer.split("\r\n").filter!(x => x.length > 0).array;

		if (received > 0 && !buffer.endsWith("\n"))
		{
			auto i = buffer.lastIndexOf('\n');
			overflow = buffer[++i .. $].dup;
			lines = lines[0 .. $ - 1];
		}

		foreach (string s; lines)
		{
			string prefix, command;

			if (s[0] == ':')
			{
				s = s[1 .. $];
				prefix = s.munch("^ ");
				s.munch(" ");
			}

			command = s.munch("^ ");

			auto wat = s.findSplit(" :");
			auto _wat = wat[0];
			_wat.munch(" ");

			string[] args = _wat.split(" ");
			args ~= wat[2];

			parseCommand(prefix, command, args);

			args.destroy();
			_wat.destroy();
			wat.destroy();
		}

		lines.destroy();
		buffer.destroy();

		socket.blocking = true;
		return _connected;
	}

	/// Get tracked user from nick name.
	/// Returns: null if user is not tracked.
	IrcUser getUser(in string nickName)
	{
		if (nickName == this.nickName)
		{
			return me;
		}

		auto search = find!(x => !sicmp(x.nickName, nickName))(users[]);
		return search.empty ? null : search.front;
	}

	/**
		Begin tracking a user.

		Params:
			prefix = Prefix of the user to be tracked.
			channel = Channel the user is in (optional). This channel will also be tracked.w
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
			auto u = IrcUser.fromPrefix(prefix);
			result.userName = u.userName.idup;
			result.hostName = u.hostName.idup;
			u.destroy();
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

		auto search = find!(x => !sicmp(x.nickName, nickName))(users[]);
		if (!search.empty)
		{
			users.linearRemove(take(search, 1));
			channels.byValue().each!(x => x.removeUser(nickName));
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

		if (u._channels.empty || (u._channels.length == 1 && u._channels[0] == channel))
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
		enforce (chan !is null, "Channel isn't tracked.");

		foreach (IrcUser user; chan._users)
		{
			chan.removeUser(user.nickName);
			if (user.channels.empty)
				removeUser(user);
		}

		channels.remove(channel);
	}

	void delegate()[] onConnect;
	void delegate(IrcUser user, in string source, in string tag, in string data)[] onCtcpQuery;
	void delegate(IrcUser user, in string source, in string tag, in string data)[] onCtcpReply;
	void delegate(IrcUser user, in string target, in string channel)[] onInvite;
	void delegate(IrcUser user, in string channel)[] onJoin;
	void delegate(IrcUser kicker, in string channel, in string kickedNick, in string comment)[] onKick;
	void delegate(IrcUser user, in string target, in string message)[] onMessage;
	void delegate(IrcUser user, in string target, in string modes, in string[] args)[] onMode;
	void delegate(in string message)[] onMotdEnd;
	void delegate(in string line)[] onMotdLine;
	void delegate(in string message)[] onMotdStart;
	void delegate(in string channel, in string[] nickNames)[] onNameList;
	void delegate(in string channel)[] onNameListEnd;
	void delegate(IrcUser user, in string newNick)[] onNickChange;
	bool delegate(in string oldNick)[] onNickInUse;
	void delegate(IrcUser user, in string target, in string message)[] onNotice;
	void delegate(IrcUser user, in string channel)[] onPart;
	void delegate(IrcUser user, in string comment)[] onQuit;
	void delegate(in string channel)[] onSuccessfulJoin;
	void delegate(in string channel, in string topic)[] onTopic;
	void delegate(IrcUser user, in string channel, in string topic)[] onTopicChange;
	void delegate(in string channel, in string nick, in string time)[] onTopicInfo;
	void delegate(in IrcUser[] users)[] onUserhostReply;
	void delegate(in string nick, in string accountName)[] onWhoisAccountReply;
	void delegate(in string nick, in string[] channels)[] onWhoisChannelsReply;
	void delegate(in string nick)[] onWhoisEnd;
	void delegate(in string nick, int idleTime)[] onWhoisIdleReply;
	void delegate(in string nick)[] onWhoisOperatorReply;
	void delegate(IrcUser userInfo)[] onWhoisReply;
	void delegate(in string nick, in string serverHostName, in string serverInfo)[] onWhoisServerReply;
	void delegate(in string channel, int seconds)[] onJoinTooSoon;

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
		string tag = m.munch("^ ");
		m.munch(" ");
		raiseEvent(event, user, target, tag, m);
	}

	void parseCommand(in string prefix, in string command, in string[] args)
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

			case Mode:
				auto user = getUserFromPrefix(prefix);
				auto nicks = args.length > 2 ? args[2 .. $] : null;

				if (nicks !is null)
				{
					nicks = nicks.filter!(x => !x.empty).array;
				}

				user.resetActionTime();
				raiseEvent(onMode, user, args[0], args[1], nicks);
				if (args[0].isChannel)
				{
					auto channel = args[0].idup;
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
				auto user = getUserFromPrefix(prefix);
				auto message = args[1];
				bool ctcp = isCtcp(message);
				user.resetActionTime();

				if (ctcp)
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
				auto user = getUserFromPrefix(prefix);
				auto message = args[1];
				bool ctcp = isCtcp(message);
				user.resetActionTime();

				if (ctcp)
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
				auto user = getUserFromPrefix(prefix);
				auto newNick = args[0];
				user.resetActionTime();
				raiseEvent(onNickChange, user, newNick);

				// rename user in all channels where user is present
				channels.byValue()
					.filter!(x => user.channels.canFind(x.name))
					.each!(x => x.renameUser(user.nickName, newNick));

				user.nickName = newNick.idup;
				break;

			case Join:
				if (!sicmp(getNickName(prefix), nickName))
				{
					auto channel = args[0].idup;
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
				auto names = args[3].split.filter!(x => x.length > 0);
				foreach (string s; names)
				{
					auto nick = s.idup;
					auto modes = nick.munch(channelUserPrefixes.replace("^", "\\^"));

					if (sicmp(nick, nickName) != 0) // skip self; added on join.
					{
						addUser(nick, channel);
					}

					if (!modes.empty)
					{
						channels[channel.idup].setMode(nick, modes[0]);
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
				auto user = getUser(args[5]);

				if (user !is null)
				{
					auto rname = args[7].idup;
					rname.munch("0-9 ");

					user.userName = args[2].idup;
					user.hostName = args[3].idup;
					user.realName = rname;

					auto mode  = args[6].idup;
					mode.munch("^" ~ channelUserPrefixes.replace("^", "\\^"));

					if (!mode.empty)
					{
						channels[args[1]].setMode(user.nickName, mode[0]);
					}
				}
				break;

			case Part:
				auto user = getUserFromPrefix(prefix);
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
				auto user = getUserFromPrefix(prefix);
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
				auto user = getUserFromPrefix(prefix);
				string message = !args.empty ? args[0] : null;
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
				auto user = getUser(args[1]);
				if (user is null)
				{
					user = new IrcUser(args[1], args[2], args[3], args[5]);
				}
				else
				{
					user.nickName = args[1].idup;
					user.userName = args[2].idup;
					user.hostName = args[3].idup;
					user.realName = args[5].idup;
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
				auto nick = args[1];
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
					raiseEvent(onWhoisAccountReply, args[1], args[1]);
				break;

			case RPL_WHOISACCOUNT:
				raiseEvent(onWhoisAccountReply, args[1], args[2]);
				break;

			case RPL_USERHOST: // TODO: onUserhostReply
				break;

			case "005":
				auto trimmed = args[1 .. $ - 1];

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
							if (!value.empty)
							{
								enforce(value[0] == '(');

								auto end = value.indexOf(')');
								enforce(end != -1 && end != value.length - 1);

								auto modes = value[1 .. end];
								auto prefixes = value[end + 1 .. $];
								enforce(modes.length == prefixes.length);

								_channelUserModes    = modes.dup;
								_channelUserPrefixes = prefixes.dup;
							}
							break;

						case "CHANMODES":
							if (value.empty)
							{
								break;
							}

							const(char)[][4] modeTypes;

							modeTypes = value.split(',');

							if (channelListModes != modeTypes[0])
							{
								channelListModes = modeTypes[0].idup;
							}

							if (channelParameterizedModes != modeTypes[1])
							{
								channelParameterizedModes = modeTypes[1].idup;
							}

							if (channelNullaryRemovableModes != modeTypes[2])
							{
								channelNullaryRemovableModes = modeTypes[2].idup;
							}

							if (channelSettingModes != modeTypes[3])
							{
								channelSettingModes = modeTypes[3].idup;
							}
							break;

						case "NICKLEN":
							if (!value.empty)
							{
								maxNickLength = to!(typeof(maxNickLength))(value);
							}

							break;

						case "NETWORK":
							if (!value.empty)
							{
								_networkName = value.idup;
							}

							break;
					}
				}

				break;

				//[1] = {length=5 "#test"}
				//[2] = {length=57 "You must wait 5 seconds after being kicked to rejoin (+J)"}
			case JoinTooSoon:
				auto whatever = args[2].dup;
				whatever.munch("^0-9");
				enforce(!whatever.empty);
				auto seconds_str = whatever.munch("0-9");
				whatever.munch(" ");
				auto seconds = to!int(seconds_str);

				if (whatever.startsWith("second"))
				{
					raiseEvent(onJoinTooSoon, args[1], seconds);
				}
				break;
		}
	}

	static void raiseEvent(E, A...)(E[] event, A args)
	{
		event.each!(x => x(args));
	}

	static bool isCtcp(in string message)
	{
		auto m = matchAll(message, ctcpRegex);
		bool result = !m.empty;
		m.destroy();
		return result;
	}
}

struct ConnectionInfo
{
	string address;
	ushort explicitPort;

	ushort port() @property const
	{
		return !explicitPort ? defaultPort : explicitPort;
	}

	string[] channels;
	string channelKey;

	ushort defaultPort() @property const
	{
		return 6667;
	}
}
