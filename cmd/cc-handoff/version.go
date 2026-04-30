package main

import (
	"fmt"

	"github.com/cc-collaboration/internal/version"
)

func runVersion() {
	fmt.Println(version.Full())
}
