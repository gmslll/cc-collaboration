package relay_test

import (
	"os"
	"strings"
	"testing"
)

func TestInboxCommentsMapsStoreErrors(t *testing.T) {
	src, err := os.ReadFile("server.go")
	if err != nil {
		t.Fatal(err)
	}
	js := string(src)
	start := strings.Index(js, "func (s *Server) listInboxComments")
	if start < 0 {
		t.Fatal("could not locate listInboxComments")
	}
	end := strings.Index(js[start:], "\nfunc (s *Server) putAttachment")
	if end < 0 {
		t.Fatal("could not locate end of listInboxComments")
	}
	body := js[start : start+end]
	if !strings.Contains(body, "writeStoreError(w, err)") {
		t.Fatal("listInboxComments should map store sentinel errors with writeStoreError")
	}
	if strings.Contains(body, "http.StatusInternalServerError") {
		t.Fatal("listInboxComments still maps store errors to a hard-coded 500")
	}
}
