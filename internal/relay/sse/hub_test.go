package sse

import (
	"reflect"
	"testing"
)

func TestHubOnlineRecipientsDedupesAndSorts(t *testing.T) {
	h := NewHub()

	_, cancelAlice1 := h.Subscribe("alice")
	_, cancelAlice2 := h.Subscribe("alice")
	_, cancelBob := h.Subscribe("bob")

	got := h.OnlineRecipients()
	want := []string{"alice", "bob"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("OnlineRecipients = %v, want %v", got, want)
	}

	cancelAlice1()
	got = h.OnlineRecipients()
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("after one alice cancel, OnlineRecipients = %v, want %v", got, want)
	}

	cancelAlice2()
	got = h.OnlineRecipients()
	if !reflect.DeepEqual(got, []string{"bob"}) {
		t.Fatalf("after both alice cancels, OnlineRecipients = %v, want [bob]", got)
	}

	cancelBob()
	got = h.OnlineRecipients()
	if len(got) != 0 {
		t.Fatalf("after all cancels, OnlineRecipients = %v, want []", got)
	}
}
