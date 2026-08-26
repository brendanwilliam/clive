#!/bin/zsh
set -euo pipefail

METRICS_FILE=${CLIVE_SCRIPT_PERFORMANCE_FILE:-${HOME}/Library/Application Support/Clive/Development/script-runs.tsv}

if [[ ! -f ${METRICS_FILE} ]]; then
    echo "No script performance samples have been recorded yet."
    echo "Metrics file: ${METRICS_FILE}"
    exit 0
fi

printf "%-24s %6s %9s %8s  %s\n" "script" "runs" "average" "failed" "last 5 runs"
awk -F '\t' '
    {
        name = $2
        runs[name]++
        total[name] += $4
        if ($3 != 0) failures[name]++
        duration[name, runs[name]] = $4
    }
    END {
        for (name in runs) {
            first = runs[name] > 5 ? runs[name] - 4 : 1
            recent = ""
            for (sample = first; sample <= runs[name]; sample++) {
                recent = recent (recent == "" ? "" : ", ") duration[name, sample] "s"
            }
            printf "%-24s %6d %8.3fs %8d  %s\n", name, runs[name], total[name] / runs[name], failures[name], recent
        }
    }
' "${METRICS_FILE}" | sort

echo "Metrics file: ${METRICS_FILE}"
