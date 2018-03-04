module libdirc.helper;

/**
	Returns a slice of `arr` from 0 until the index where `pred` is satisfied.
	`arr` is narrowed to the range after that point.

	Params:
		pred = Predicate.
		arr  = Array to search.

	Returns:
		Slice of `arr`.
 */
R[] takeUntil(alias pred, R)(ref R[] arr)
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

/**
	Returns a slice of `arr` from 0 until the index where `element` is found.
	`arr` is narrowed to the range after that point.

	Params:
		arr     = Array to search.
		element = The element to search for.

	Returns:
		Slice of `arr`.
 */
R[] takeUntil(R)(ref R[] arr, in R element)
{
	foreach (size_t i, e; arr)
	{
		if (e == element)
		{
			auto result = arr[0 .. i];
			arr = arr[(i > $ ? $ : i) .. $];
			return result;
		}
	}

	return arr;
}

/**
	Returns a slice of `arr` from 0 until the index where any element of `a` is found.
	`arr` is narrowed to the range after that point.

	Params:
		arr = Array to search.
		a   = The elements to search for.

	Returns:
		Slice of `arr`.
 */
R[] takeUntilAny(R)(ref R[] arr, R[] a)
{
	foreach (size_t i, e; arr)
	{
		if (a.any!((x) => x == e))
		{
			auto result = arr[0 .. i];
			arr = arr[(i > $ ? $ : i) .. $];
			return result;
		}
	}

	return arr;
}

/**
	Returns a slice of `arr` from 0 until the last index where `pred` is satisfied.
	`arr` is narrowed to the range after that point.

	Params:
		pred = Predicate.
		arr  = Array to search.

	Returns:
		Slice of `arr`.
 */
R[] takeWhile(alias pred, R)(ref R[] arr)
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

/**
	Returns a slice of `arr` from 0 until the index where `element` is no longer found.
	`arr` is narrowed to the range after that point.

	Params:
		arr     = Array to search.
		element = The element to search for.

	Returns:
		Slice of `arr`.
 */
R[] takeWhile(R)(ref R[] arr, in R element)
{
	foreach (size_t i, e; arr)
	{
		if (e == element)
		{
			continue;
		}

		auto result = arr[0 .. i];
		arr = arr[(i > $ ? $ : i) .. $];
		return result;
	}

	return arr;
}

/**
	Returns a slice of `arr` from 0 until the index where no elements of `a` are found.
	`arr` is narrowed to the range after that point.

	Params:
		arr = Array to search.
		a   = The elements to search for.

	Returns:
		Slice of `arr`.
 */
R[] takeWhileAny(R)(ref R[] arr, R[] a)
{
	foreach (size_t i, e; arr)
	{
		if (a.any!((x) => x == e))
		{
			continue;
		}

		auto result = arr[0 .. i];
		arr = arr[(i > $ ? $ : i) .. $];
		return result;
	}

	return arr;
}
