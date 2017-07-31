module libdirc.util;

import std.exception : enforce;

/// Checks the first character of the given string for '#'.
bool isChannel(in string str)
{
	return str.length && str[0] == '#';
}

/// Returns the nick name portion of a user prefix.
string getNickName(in string prefix)
{
	import std.regex;

	static auto r = ctRegex!(`[!\s]`);

	return splitter(prefix, r).front;
}

/// Convenience function for enforcing `str.isChannel`
void enforceChannel(string str)
{
	enforce(str.isChannel, "Input string is not a valid channel string.");
}

/// Convenience function for enforcing non-null parameters.
void enforceNotNull(string str, string name)
{
	enforce(str.length, name ~ " must not be empty.");
}
