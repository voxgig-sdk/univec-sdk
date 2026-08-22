
import { cmp, Content } from '@voxgig/sdkgen'


// Emit a documentation clojure-examples SYNTAX gate INTO the shared gentest run
// body (the clojure test runner drives a single sdk.gentest/run). For each doc
// that ships clojure examples — the repository ROOT README.md, the per-language
// README.md, and REFERENCE.md — every ```clojure fenced block is extracted and
// PARSED with read-string (all forms wrapped in a vector), catching a malformed
// documented example (an unbalanced paren, a bad token, an unclosed string).
//
// SCOPE NOTE: like the elixir gate, this stops at the syntax check rather than
// EXECUTING each block. Running a README fragment against the generated
// namespaces would need the SDK loaded and the narrative requires resolved for
// every block; the syntax gate is a real, useful guard that keeps documented
// examples parseable as the generator evolves. A doc that is absent at test
// time is skipped (passes), so the gate never hard-fails on a missing file.
//
// The emitted clojure builds the triple-backtick fence from (char 96) so this
// TS template literal needs no embedded backticks.
const ReadmeExamplesTest = cmp(function ReadmeExamplesTest(_props: any) {

  Content(`  (letfn [(fence-pat [] (re-pattern (apply str (repeat 3 (char 96)))))
          (fence-count [text] (count (re-seq (fence-pat) text)))
          (clj-blocks [text]
            (let [parts (clojure.string/split text (fence-pat))]
              (->> parts
                   (map-indexed vector)
                   (filter (fn [[i _]] (odd? i)))
                   (map (fn [[_ seg]] seg))
                   (filter (fn [seg]
                             (= "clojure"
                                (clojure.string/trim (first (clojure.string/split-lines seg))))))
                   (map (fn [seg]
                          (clojure.string/join "\\n"
                            (rest (clojure.string/split-lines seg))))))))]
    (doseq [[label path] [["root-README" "../README.md"]
                          ["README" "README.md"]
                          ["REFERENCE" "REFERENCE.md"]]]
      (t/run-check rec (str "gen-readme-examples-" label)
        (fn []
          (if-not (.exists (java.io.File. ^String path))
            (t/is-true true (str label " absent (skipped)"))
            (let [text (slurp path)]
              ;; A code fence opened but never closed leaves an ODD number of
              ;; fence markers; the split-on-fence then captures the trailing
              ;; prose (everything after the last opener) as if it were a
              ;; clojure block, which can parse cleanly and pass silently. Fail
              ;; on the malformed doc instead. (Count markers directly rather
              ;; than split parts: split drops trailing empty segments, so a
              ;; closing fence at EOF would be miscounted.)
              (t/is-true (even? (fence-count text))
                         (str label " code fences balanced (no unclosed fence)"))
              (let [blocks (clj-blocks text)]
                (doseq [b blocks]
                  (binding [*read-eval* false]
                    (read-string (str "[\\n" b "\\n]"))))
                (t/is-true true (str label " clojure blocks parse cleanly")))))))))
`)
})


export {
  ReadmeExamplesTest
}
