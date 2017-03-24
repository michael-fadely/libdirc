module libdirc.channel;

import std.algorithm;
import std.container.slist;
import std.range;
import std.string;
import std.uni;

import libdirc.client;
import libdirc.helper;
import libdirc.user;

debug import std.stdio;

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
		u.removeChannel(name);
	}

	/// Begins tracking a user in this channel.
	void addUser(IrcUser user)
	{
		user.addChannel(name);
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
