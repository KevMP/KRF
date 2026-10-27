--!strict
-- Logging only: one first/actionable message per category per process window.
-- Fixed categories cap total output independently of client/Actor churn.
return table.freeze({ WARNING_WINDOW_SECONDS = 10, WARNINGS_PER_WINDOW = 1 })
