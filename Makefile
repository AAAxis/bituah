.PHONY: run test eval testset demo clean
run:      ; ./run.sh
test:     ; swift test
eval:     ; swift run -c release bituah eval -o metrics.json
testset:  ; swift run -c release bituah make-testset Samples --out Samples/variants
demo:     ; swift run BituahDemo
clean:    ; rm -rf .build
