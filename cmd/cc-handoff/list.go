package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/transport"
	"github.com/cc-collaboration/pkg/handoffschema"
)

func runList(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("list", flag.ContinueOnError)
	asJSON := fs.Bool("json", false, "emit JSON instead of a table")
	projectID := fs.String("project", "", "show project-shared handoffs for this project id")
	allProjects := fs.Bool("all-projects", false, "show project-shared handoffs across all projects I belong to")
	limit := fs.Int("limit", 100, "max items for project-shared listing")
	if err := fs.Parse(args); err != nil {
		return err
	}

	cwd, err := os.Getwd()
	if err != nil {
		return err
	}
	res, err := config.ResolveRelay(cwd)
	if err != nil {
		return err
	}
	client := transport.New(res.RelayURL, res.Token)
	var listItems []handoffschema.ListItem
	if *projectID != "" || *allProjects {
		if *projectID != "" && *allProjects {
			return fmt.Errorf("--project and --all-projects are mutually exclusive")
		}
		listItems, err = client.ListProjectHandoffs(ctx, *projectID, *limit)
	} else {
		listItems, err = client.List(ctx, res.Me)
	}
	if err != nil {
		return err
	}
	if *asJSON {
		return json.NewEncoder(os.Stdout).Encode(listItems)
	}
	if len(listItems) == 0 {
		fmt.Println("inbox is empty.")
		return nil
	}
	fmt.Printf("%-32s  %-22s  %-7s  %-19s  %s\n", "ID", "FROM", "URG", "WHEN", "HEADLINE")
	for _, it := range listItems {
		fmt.Printf("%-32s  %-22s  %-7s  %-19s  %s\n",
			it.ID,
			truncRight(it.Sender, 22),
			it.Urgency,
			it.CreatedAt.Local().Format(time.RFC3339[:19]),
			truncRight(it.Headline, 80),
		)
	}
	return nil
}

// truncRight returns s capped at n runes, appending an ellipsis if truncated.
// Counts runes (not bytes) so it does not corrupt multi-byte characters.
func truncRight(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	runes := []rune(s)
	return strings.TrimSpace(string(runes[:n-1])) + "…"
}
