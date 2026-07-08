package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/cc-collaboration/internal/transport"
	"github.com/cc-collaboration/pkg/handoffschema"
)

// runAlert is the server-side hook entry point: forward a log alert to a
// teammate's watch via the relay. A backend's error hook (cron, log watcher)
// calls this with the developer's own relay token + identity-as-recipient, and
// the developer's watch surfaces it (and optionally auto-launches the agent).
// Servers without cc-handoff installed can POST /v1/alerts with curl instead.
func runAlert(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("alert", flag.ContinueOnError)
	to := fs.String("to", "", "recipient identity whose watch should surface this alert")
	project := fs.String("project", "", "workspace project name the receiver launches the agent in")
	teamProjectID := fs.String("team-project", "", "cc-handoff project id whose direct owners/members plus team owners/admins should receive this alert")
	orgID := fs.String("org", "", "cc-handoff organization id whose actionable members should receive this alert")
	member := fs.String("member", "", "with --team-project/--org, alert only this team member")
	level := fs.String("level", "", "severity tag for the notification subtitle (e.g. error, fatal)")
	message := fs.String("message", "", "log body / excerpt to triage")
	file := fs.String("file", "", "read the log body from this file instead of --message ('-' for stdin)")
	grade := fs.Bool("grade", false, "grade the message's severity with the configured local-AI grader and send it as --level")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *to == "" && *teamProjectID == "" && *orgID == "" {
		return fmt.Errorf("usage: cc-handoff alert [--to <identity> | --team-project <id> | --org <id>] [--member ID] --project <name> [--message TEXT | --file PATH] [--level LVL]")
	}
	if *to != "" && (*teamProjectID != "" || *orgID != "" || *member != "") {
		return fmt.Errorf("--to cannot be combined with --team-project/--org/--member")
	}
	if *member != "" && *teamProjectID == "" && *orgID == "" {
		return fmt.Errorf("--member requires --team-project or --org")
	}

	msg := *message
	if *file != "" {
		var (
			data []byte
			err  error
		)
		if *file == "-" {
			data, err = io.ReadAll(os.Stdin)
		} else {
			data, err = os.ReadFile(*file)
		}
		if err != nil {
			return fmt.Errorf("read log body: %w", err)
		}
		msg = string(data)
	}
	if msg == "" {
		return fmt.Errorf("alert message is empty; pass --message TEXT or --file PATH")
	}

	u, err := loadUserOrFail()
	if err != nil {
		return err
	}
	if u.RelayURL == "" || u.Token == "" {
		return fmt.Errorf("relay_url/token missing in user config; run `cc-handoff init`")
	}
	if (*teamProjectID != "" || *orgID != "") && u.Identity == "" {
		return fmt.Errorf("identity missing in user config; run `cc-handoff config set --identity <you>` before using team alert targets")
	}

	lvl := *level
	if *grade && lvl == "" {
		if g := gradeSeverity(ctx, u.GradeCommand, msg); g != "" {
			lvl = g
			fmt.Printf("graded severity: %s\n", lvl)
		}
	}

	client := transport.New(u.RelayURL, u.Token)
	recipients := []string{*to}
	if *teamProjectID != "" || *orgID != "" {
		recipients, err = client.ResolveTeamRecipients(ctx, *teamProjectID, *orgID, u.Identity, *member)
		if err != nil {
			return err
		}
		if len(recipients) == 0 {
			if *teamProjectID != "" {
				return fmt.Errorf("project %s has no actionable alert recipients (direct owners/members or team owners/admins)", *teamProjectID)
			}
			return fmt.Errorf("organization %s has no actionable alert recipients", *orgID)
		}
	}
	for _, recipient := range recipients {
		if err := client.Alert(ctx, &handoffschema.LogAlert{
			Recipient: recipient,
			Project:   *project,
			Level:     lvl,
			Message:   msg,
		}); err != nil {
			return err
		}
	}
	fmt.Printf("alert sent to %s", formatRecipientTarget(recipients))
	if *project != "" {
		fmt.Printf(" (project %s)", *project)
	}
	fmt.Println()
	return nil
}
