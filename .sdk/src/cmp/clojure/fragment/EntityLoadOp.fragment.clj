; EJECT-START
;; Load a single EntityName (reqmatch: id/query fields; nil = empty match).
(defn load [ent reqmatch ctrl]
  (let [ctx (core/make-context
             (vs/jm "opname" "load" "ctrl" ctrl
                    "match" (deref (:_match ent)) "data" (deref (:_data ent)) "reqmatch" reqmatch)
             (:_entctx ent))]
    (op-return ent ctx (run-op ctx
            (fn []
              (when-let [result (core/oget ctx :result)]
                (when (core/oget result :resmatch) (reset! (:_match ent) (core/oget result :resmatch)))
                (when (core/oget result :resdata)
                  (reset! (:_data ent)
                          (let [m (core/to-map (vs/clone (core/oget result :resdata)))] (if m m (vs/jm)))))))))))
; EJECT-END
