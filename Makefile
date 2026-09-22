.PHONY: run test eval bench testset demo clean
run:      ; ./run.sh
test:     ; swift test
eval:     ; swift run -c release bituah eval -o metrics.json
testset:  ; swift run -c release bituah make-testset Samples --out Samples/variants
bench:    ; swift run -c release bituah bench -o bench.json
demo:     ; swift run BituahDemo
clean:    ; rm -rf .build
