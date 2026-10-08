; EJECT-START
;; List EntityName items matching a filter (reqmatch: any subset of fields).
;; Resolves to a vector of entities, one per record, as make-result builds
;; them; ((:data-get item)) reads an item's record.
(defn list [ent reqmatch ctrl]
  (let [ctx (core/make-context
             (vs/jm "opname" "list" "ctrl" ctrl
                    "match" (deref (:_match ent)) "data" (deref (:_data ent)) "reqmatch" reqmatch)
             (:_entctx ent))
        items (run-op ctx
                      (fn []
                        (when-let [result (core/oget ctx :result)]
                          (when (core/oget result :resmatch) (reset! (:_match ent) (core/oget result :resmatch))))))]
    (if (vs/islist items) (vec items) items)))
; EJECT-END
