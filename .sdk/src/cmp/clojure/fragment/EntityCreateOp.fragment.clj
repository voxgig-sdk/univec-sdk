; EJECT-START
;; Create a new EntityName (reqdata: body data).
(defn create [ent reqdata ctrl]
  (let [ctx (core/make-context
             (vs/jm "opname" "create" "ctrl" ctrl
                    "match" (deref (:_match ent)) "data" (deref (:_data ent)) "reqdata" reqdata)
             (:_entctx ent))]
    (op-return ent ctx (run-op ctx
            (fn []
              (when-let [result (core/oget ctx :result)]
                (when (core/oget result :resdata)
                  (reset! (:_data ent)
                          (let [m (core/to-map (vs/clone (core/oget result :resdata)))] (if m m (vs/jm)))))))))))
; EJECT-END
