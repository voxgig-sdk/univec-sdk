; EJECT-START
;; List EntityName items matching a filter (reqmatch: any subset of fields).
;; Yields a bare vector of records (each an accessible map), unwrapping the
;; entity instances make-result produced for internal use.
(defn list [ent reqmatch ctrl]
  (let [ctx (core/make-context
             (vs/jm "opname" "list" "ctrl" ctrl
                    "match" (deref (:_match ent)) "data" (deref (:_data ent)) "reqmatch" reqmatch)
             (:_entctx ent))
        records (run-op ctx
                        (fn []
                          (when-let [result (core/oget ctx :result)]
                            (when (core/oget result :resmatch) (reset! (:_match ent) (core/oget result :resmatch))))))]
    (if (vs/islist records)
      (mapv (fn [item] (if (and (map? item) (:data-get item)) ((:data-get item)) item)) (vec records))
      records)))
; EJECT-END
