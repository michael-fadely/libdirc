module libdirc.helper;

R takeUntil(alias pred, R)(ref R arr)
{
	foreach (size_t i, e; arr)
	{
		if (pred(e))
		{
			auto result = arr[0 .. i];
			arr = arr[(i > $ ? $ : i) .. $];
			return result;
		}
	}

	return arr;
}

R takeWhile(alias pred, R)(ref R arr)
{
	foreach (size_t i, e; arr)
	{
		if (!pred(e))
		{
			auto result = arr[0 .. i];
			arr = arr[(i > $ ? $ : i) .. $];
			return result;
		}
	}

	return arr;
}
