; EJECT-START
;; Remove an EntityName matching the criteria (reqmatch: id/query fields).
;; Resolves to THIS entity, marked as deleted (see AGENTS.md). The instance
;; keeps the data it held, so a caller can still read what was removed.
(defn remove [ent reqmatch ctrl]
  (let [ctx (core/make-context
             (vs/jm "opname" "remove" "ctrl" ctrl
                    "match" (deref (:_match ent)) "data" (deref (:_data ent)) "reqmatch" reqmatch)
             (:_entctx ent))
        out (op-return ent ctx
                       (run-op ctx
                               (fn []
                                 (when-let [result (core/oget ctx :result)]
                                   (when (core/oget result :resmatch) (reset! (:_match ent) (core/oget result :resmatch)))
                                   (when (core/oget result :resdata)
                                     (reset! (:_data ent)
                                             (let [m (core/to-map (vs/clone (core/oget result :resdata)))] (if m m (vs/jm)))))))))]
    (if (= out ent) (mark-deleted ent) out)))
; EJECT-END
