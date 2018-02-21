import core.thread;

import std.datetime;
import std.exception;
import std.socket;
import std.stdio;

import libdirc;

class whatever
{
private:
	IrcClient _client;

public:
	this(IrcClient client)
	{
		client.onConnect        ~= &onConnect;
		client.onSuccessfulJoin ~= &onJoined;

		_client = client;
	}

	void onConnect()
	{
		_client.join("#test");
	}

	void onJoined(in string channel)
	{
		import std.array : replicate;
		stdout.writeln("Joined " ~ channel);
		string message = replicate("ABCDEFGHIJKLMNOPQRSTUVWXYZ ", 28);
		_client.send(channel, "Incoming length test. The following should be 28 complete alphabets separated by space: ");
		_client.send(channel, message);
	}
}

int main()
{
	Address[] addresses;

	try
	{
		addresses = getAddress("127.0.0.1", 6667);
		enforce(addresses.length, "Address not found.");
	}
	catch (Exception ex)
	{
		stderr.writeln(ex.msg);
		return -1;
	}

	// nickName, userName, (optional) realName
	IrcClient client = new IrcClient("Neko-test", "Neko-test", "Neko-test");
	auto w = new whatever(client);

	for (int i = 1; i <= 10; i++)
	{
		try
		{
			client.connect(addresses[0]);
			break;
		}
		catch (Exception ex)
		{
			stderr.writeln(ex.msg);

			if (i == 10)
			{
				stderr.writeln("Aborting after 10 retries.");
				return -1;
			}

			Thread.sleep(1.seconds);
		}
	}

	while (client.read())
	{
		Thread.sleep(1.msecs);
	}

	return 0;
}
