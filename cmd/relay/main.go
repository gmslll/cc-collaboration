package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/cc-collaboration/internal/relay"
	"github.com/cc-collaboration/internal/relay/auth"
	"github.com/cc-collaboration/internal/relay/sse"
	"github.com/cc-collaboration/internal/relay/store"
)

func main() {
	// Bootstrap subcommand: create/reset an account (and its admin flag) directly
	// on the relay host — the chicken-and-egg fix for admin-only account
	// management. Run as the operator on the VPS.
	if len(os.Args) > 1 && os.Args[1] == "useradd" {
		if err := runUserAdd(os.Args[2:]); err != nil {
			log.Fatalf("useradd: %v", err)
		}
		return
	}

	addr := flag.String("addr", ":8080", "listen address")
	dbPath := flag.String("db", "relay.db", "sqlite database file")
	tokensPath := flag.String("tokens", "tokens.json", "JSON file mapping tokens to identities")
	adminsFlag := flag.String("admins", "", "comma-separated seed admin identities (falls back to RELAY_ADMINS)")
	flag.Parse()

	st, err := store.Open(*dbPath)
	if err != nil {
		log.Fatalf("open store: %v", err)
	}
	defer st.Close()

	tokens := auth.NewTokens()
	if err := tokens.LoadFile(*tokensPath); err != nil {
		// A missing tokens file is fine now that accounts + sessions exist —
		// the relay can run on accounts alone. Only a malformed file is fatal.
		if errors.Is(err, os.ErrNotExist) {
			log.Printf("no tokens file at %s — relying on accounts / sessions / DB-minted tokens", *tokensPath)
		} else {
			log.Fatalf("load tokens: %v", err)
		}
	}
	log.Printf("loaded %d legacy file tokens", tokens.Count())

	seedAdmins := parseAdmins(*adminsFlag)
	if len(seedAdmins) > 0 {
		log.Printf("seed admins: %s", strings.Join(seedAdmins, ", "))
	}

	hub := sse.NewHub()
	srv := &http.Server{
		Addr:              *addr,
		Handler:           (&relay.Server{Store: st, Tokens: tokens, Hub: hub, SeedAdmins: seedAdmins}).Handler(),
		ReadHeaderTimeout: 5 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	go func() {
		log.Printf("relay listening on %s", *addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("listen: %v", err)
		}
	}()

	<-ctx.Done()
	log.Printf("shutting down")
	shutCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutCtx)
}

// parseAdmins splits the -admins flag (or RELAY_ADMINS env when empty) into a
// deduped identity list.
func parseAdmins(flagVal string) []string {
	raw := flagVal
	if raw == "" {
		raw = os.Getenv("RELAY_ADMINS")
	}
	seen := map[string]bool{}
	var out []string
	for _, p := range strings.Split(raw, ",") {
		if p = strings.TrimSpace(p); p == "" || seen[p] {
			continue
		}
		seen[p] = true
		out = append(out, p)
	}
	return out
}

// runUserAdd creates (or, if it exists, resets the password + admin flag of) an
// account. With no --password it generates one and prints it once.
func runUserAdd(args []string) error {
	fs := flag.NewFlagSet("useradd", flag.ExitOnError)
	dbPath := fs.String("db", "relay.db", "sqlite database file")
	identity := fs.String("identity", "", "account identity (e.g. you@backend)")
	admin := fs.Bool("admin", false, "grant global admin")
	password := fs.String("password", "", "initial password (generated + printed when empty)")
	display := fs.String("display", "", "display name")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *identity == "" {
		return fmt.Errorf("--identity is required (e.g. --identity you@backend)")
	}

	st, err := store.Open(*dbPath)
	if err != nil {
		return err
	}
	defer st.Close()

	pw, generated := *password, false
	if pw == "" {
		gen, err := auth.GeneratePassword()
		if err != nil {
			return err
		}
		pw, generated = gen, true
	}
	hash, err := auth.HashPassword(pw)
	if err != nil {
		return err
	}

	ctx := context.Background()
	switch _, err := st.GetUser(ctx, *identity); {
	case errors.Is(err, store.ErrNotFound):
		if err := st.CreateUser(ctx, store.User{
			Identity: *identity, PasswordHash: hash, DisplayName: *display, IsAdmin: *admin,
		}, time.Now()); err != nil {
			return err
		}
		fmt.Printf("created account %q (admin=%v)\n", *identity, *admin)
	case err != nil:
		return err
	default:
		if err := st.SetPasswordHash(ctx, *identity, hash); err != nil {
			return err
		}
		if err := st.SetAdmin(ctx, *identity, *admin); err != nil {
			return err
		}
		fmt.Printf("updated account %q (admin=%v)\n", *identity, *admin)
	}
	if generated {
		fmt.Printf("password: %s\n", pw)
	}
	return nil
}
