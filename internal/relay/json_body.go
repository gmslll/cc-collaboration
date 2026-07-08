package relay

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
)

var errUnexpectedTrailingJSON = errors.New("unexpected trailing json")

func decodeJSONBody(w http.ResponseWriter, r *http.Request, maxBytes int64, dst any) error {
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBytes))
	if err := dec.Decode(dst); err != nil {
		return err
	}
	return rejectTrailingJSON(dec)
}

func rejectTrailingJSON(dec *json.Decoder) error {
	var extra json.RawMessage
	if err := dec.Decode(&extra); err != io.EOF {
		if err == nil {
			return errUnexpectedTrailingJSON
		}
		return err
	}
	return nil
}
