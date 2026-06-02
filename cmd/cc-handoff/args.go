package main

import "flag"

// parseFlexible parses fs allowing flags and positionals to be interleaved in
// any order, and returns the positionals. Go's flag package stops at the first
// non-flag token, so `cmd <project> <branch> --open` would otherwise leave
// --open unparsed. We loop: Parse consumes leading flags (including their
// values, e.g. --start REF), we peel off the next positional, and continue on
// the remainder until nothing is left.
func parseFlexible(fs *flag.FlagSet, args []string) ([]string, error) {
	var positional []string
	for len(args) > 0 {
		if err := fs.Parse(args); err != nil {
			return nil, err
		}
		args = fs.Args()
		if len(args) == 0 {
			break
		}
		positional = append(positional, args[0])
		args = args[1:]
	}
	return positional, nil
}
