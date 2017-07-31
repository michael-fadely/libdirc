module libdirc.user;

import core.time;
import std.string;

import libdirc.helper;

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

		/// Gets or sets an array of channels this user is associated with.
		auto channels() const
		{
			return _channels;
		}

		/// Returns the time of the last recorded action performed by this user.
		/// See_Also: resetActionTime, isIdle, idleTime
		auto lastActionTime() { return _lastActionTime; }
	}

	/// Associate a channel with this user.
	void addChannel(in string channel)
	{
		_channels ~= channel;
	}
	/// Remove a channel association from this user.
	void removeChannel(in string channel)
	{
		import std.algorithm : remove;
		import std.uni       : sicmp;

		_channels = _channels.remove!(x => !sicmp(x, channel));
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

	/// Constructs an `IrcUser` from a prefix string.
	static IrcUser fromPrefix(string prefix)
	{
		IrcUser result;

		if (prefix !is null)
		{
			string userName, hostName;
			string nickName = prefix.takeUntil!(x => x == '!');

			if (!prefix.empty)
			{
				prefix = prefix[1 .. $];
				userName = prefix.takeUntil!(x => x == '@');

				if (prefix.length)
				{
					hostName = prefix[1 .. $];
				}
			}

			result = new IrcUser(nickName, userName, hostName);
		}

		return result;
	}
}

///
unittest
{
	const user = new IrcUser("nick", "user", "host");
	assert(user.toString() == "nick!user@host");

	const prefix = IrcUser.fromPrefix("nick!user@host");
	assert(prefix.nickName == "nick");
	assert(prefix.userName == "user");
	assert(prefix.hostName == "host");
	assert(prefix.toString() == "nick!user@host");

	const notUser = IrcUser.fromPrefix("irc.server.net");
	assert(notUser.nickName == "irc.server.net");
}
