{ n++; if (split($4, x, "/") == 2 && x[1] + 0 < x[2] + 0) r++
    if (split($5, y, "/") == 2) { split(y[1], c, "x"); split(y[2], m, "x"); if (c[1] + 0 < m[1] + 0 || c[2] + 0 < m[2] + 0) p++ } }
    END { printf "%d NICs read; rx ring below its maximum on %d, PCIe link below its maximum on %d", n, r, p }
