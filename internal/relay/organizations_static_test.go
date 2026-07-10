package relay_test

import (
	"os"
	"strings"
	"testing"
)

func TestCreateOrganizationMapsStoreErrors(t *testing.T) {
	src, err := os.ReadFile("organizations.go")
	if err != nil {
		t.Fatal(err)
	}
	goSrc := string(src)
	start := strings.Index(goSrc, "func (s *Server) createOrganization")
	if start < 0 {
		t.Fatal("could not locate createOrganization")
	}
	end := strings.Index(goSrc[start:], "\nfunc (s *Server) listOrganizations")
	if end < 0 {
		t.Fatal("could not locate end of createOrganization")
	}
	body := goSrc[start : start+end]
	if !strings.Contains(body, "s.writeStoreErr(w, err)") {
		t.Fatal("createOrganization should map store sentinel errors with writeStoreErr")
	}
	if strings.Contains(body, "http.StatusInternalServerError") {
		t.Fatal("createOrganization still maps store errors to a hard-coded 500")
	}
}
