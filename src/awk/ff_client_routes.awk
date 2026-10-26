
    BEGIN { n = split(rl, q, " "); for (i = 1; i <= n; i++) { split(q[i], kv, "="); R[kv[1]] = kv[2] } }
    $1 == "@@CROUTE" { d = $3; dc = index(decl, " " d " "); print h, (dc ? d : "-"), R[$2], $2, d, (dc ? "declared" : "undeclared"); seen = 1 }
    END { if (!seen) print h, "-", "-", "-", "none", "unread" }
