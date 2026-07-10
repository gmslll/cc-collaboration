package todoschema

import "testing"

func TestTodoAssigneeLabel(t *testing.T) {
	cases := []struct {
		name string
		todo Todo
		want string
	}{
		{
			name: "identity only",
			todo: Todo{AssigneeIdentity: "dev@x"},
			want: "dev@x",
		},
		{
			name: "display with identity",
			todo: Todo{AssigneeIdentity: "dev@x", AssigneeDisplayName: "Dev"},
			want: "Dev <dev@x>",
		},
		{
			name: "same display and identity",
			todo: Todo{AssigneeIdentity: "dev@x", AssigneeDisplayName: "dev@x"},
			want: "dev@x",
		},
		{
			name: "display without identity",
			todo: Todo{AssigneeDisplayName: "Dev"},
			want: "Dev",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.todo.AssigneeLabel(); got != tc.want {
				t.Fatalf("AssigneeLabel() = %q, want %q", got, tc.want)
			}
		})
	}
}
