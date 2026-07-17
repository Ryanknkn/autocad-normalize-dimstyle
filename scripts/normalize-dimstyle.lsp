(vl-load-com)
(setq *cnd-phase* "LOAD")
(setq *cnd-error-message* nil)

(defun cnd:raise (message)
  (setq *cnd-error-message* message)
  (/ 1 0)
)

(defun cnd:safe-string (value)
  (cond
    ((null value) "")
    ((= (type value) 'STR)
      (vl-string-subst " " "\r"
        (vl-string-subst " " "\n" value)))
    ((= (type value) 'INT) (itoa value))
    ((= (type value) 'REAL) (rtos value 2 12))
    (T (vl-princ-to-string value))
  )
)

(defun cnd:join (items separator / result)
  (setq result "")
  (foreach item items
    (setq result
      (if (= result "")
        (cnd:safe-string item)
        (strcat result separator (cnd:safe-string item))
      )
    )
  )
  result
)

(defun cnd:write-report (path pairs / file)
  (setq file (open path "w" "utf8"))
  (if (null file)
    (cnd:raise (strcat "Cannot create report: " path))
  )
  (foreach pair pairs
    (write-line
      (strcat (car pair) "=" (cnd:safe-string (cdr pair)))
      file
    )
  )
  (close file)
  T
)

(defun cnd:item (collection name / result)
  (setq result
    (vl-catch-all-apply 'vla-Item (list collection name))
  )
  (if (vl-catch-all-error-p result) nil result)
)

(defun cnd:ensure-layer (document layer-name / layers layer)
  (setq layers (vla-get-Layers document))
  (setq layer (cnd:item layers layer-name))
  (if (null layer)
    (setq layer (vla-Add layers layer-name))
  )
  layer
)

(defun cnd:is-xref-block-p (block / result)
  (setq result
    (vl-catch-all-apply 'vla-get-IsXRef (list block))
  )
  (and
    (not (vl-catch-all-error-p result))
    (= result :vlax-true)
  )
)

(defun cnd:dimension-reference-p (object / name)
  (setq name
    (vl-catch-all-apply 'vla-get-ObjectName (list object))
  )
  (and
    (not (vl-catch-all-error-p name))
    (or
      (wcmatch name "AcDb*Dimension")
      (= name "AcDbLeader")
      (= name "AcDbFcf")
    )
  )
)

(defun cnd:has-dstyle-pairs-p (pairs / found)
  (setq found nil)
  (foreach item pairs
    (if
      (and
        (= (car item) 1000)
        (= (strcase (cdr item)) "DSTYLE")
      )
      (setq found T)
    )
  )
  found
)

(defun cnd:has-dstyle-override-p (ename / data xdata found)
  (setq found nil)
  (setq data (entget ename '("ACAD")))
  (setq xdata (assoc -3 data))
  (if xdata
    (foreach app (cdr xdata)
      (if
        (and
          (= (strcase (car app)) "ACAD")
          (cnd:has-dstyle-pairs-p (cdr app))
        )
        (setq found T)
      )
    )
  )
  found
)

(defun cnd:strip-dstyle-pairs (pairs / output item skipping depth found)
  (setq output nil
        skipping nil
        depth 0
        found nil)
  (foreach item pairs
    (cond
      ((not skipping)
        (if
          (and
            (= (car item) 1000)
            (= (strcase (cdr item)) "DSTYLE")
          )
          (setq skipping T
                depth 0
                found T)
          (setq output (cons item output))
        )
      )
      (skipping
        (cond
          ((and (= (car item) 1002) (= (cdr item) "{"))
            (setq depth (1+ depth))
          )
          ((and (= (car item) 1002) (= (cdr item) "}"))
            (setq depth (1- depth))
            (if (<= depth 0)
              (setq skipping nil
                    depth 0)
            )
          )
        )
      )
    )
  )
  (list found (reverse output))
)

(defun cnd:clear-dstyle-overrides (ename / data xdata applications output result changed)
  (setq data (entget ename '("*")))
  (setq xdata (assoc -3 data))
  (setq changed nil)
  (if xdata
    (progn
      (setq applications (cdr xdata)
            output nil)
      (foreach app applications
        (if (= (strcase (car app)) "ACAD")
          (progn
            (setq result (cnd:strip-dstyle-pairs (cdr app)))
            (if (car result)
              (progn
                (setq changed T)
                (if (cadr result)
                  (setq output
                    (cons
                      (cons (car app) (cadr result))
                      output
                    )
                  )
                  (setq output (cons (list (car app)) output))
                )
              )
              (setq output (cons app output))
            )
          )
          (setq output (cons app output))
        )
      )
      (if changed
        (progn
          (setq data
            (subst
              (cons -3 (reverse output))
              xdata
              data
            )
          )
          (if (null (entmod data))
            (cnd:raise "Failed to remove a per-entity dimension override.")
          )
          (entupd ename)
        )
      )
    )
  )
  changed
)

(defun cnd:set-object-style (object style-name layer-name / ename update-result)
  (vla-put-StyleName object style-name)
  (vla-put-Layer object layer-name)
  (setq update-result
    (vl-catch-all-apply 'vla-Update (list object))
  )
  (setq ename (vlax-vla-object->ename object))
  (cnd:clear-dstyle-overrides ename)
  (if (vl-catch-all-error-p update-result)
    (cnd:raise (vl-catch-all-error-message update-result))
  )
  T
)

(defun cnd:apply-style-everywhere (document style-name layer-name / blocks updated dimensions leaders tolerances errors result object-name)
  (setq blocks (vla-get-Blocks document)
        updated 0
        dimensions 0
        leaders 0
        tolerances 0
        errors nil)
  (vlax-for block blocks
    (if (not (cnd:is-xref-block-p block))
      (vlax-for object block
        (if (cnd:dimension-reference-p object)
          (progn
            (setq object-name (vla-get-ObjectName object))
            (cond
              ((wcmatch object-name "AcDb*Dimension")
                (setq dimensions (1+ dimensions)))
              ((= object-name "AcDbLeader")
                (setq leaders (1+ leaders)))
              ((= object-name "AcDbFcf")
                (setq tolerances (1+ tolerances)))
            )
            (setq result
              (vl-catch-all-apply
                'cnd:set-object-style
                (list object style-name layer-name)
              )
            )
            (if (vl-catch-all-error-p result)
              (setq errors
                (cons
                  (strcat
                    (vla-get-Name block)
                    "|"
                    (vla-get-Handle object)
                    "|"
                    (vl-catch-all-error-message result)
                  )
                  errors
                )
              )
              (setq updated (1+ updated))
            )
          )
        )
      )
    )
  )
  (list
    (cons 'updated updated)
    (cons 'dimensions dimensions)
    (cons 'leaders leaders)
    (cons 'tolerances tolerances)
    (cons 'errors (reverse errors))
  )
)

(defun cnd:scan-references (document target-style target-layer / blocks total dimensions leaders tolerances mismatches layer-mismatches overrides errors xref-names object-name style-result layer-result ename-result)
  (setq blocks (vla-get-Blocks document)
        total 0
        dimensions 0
        leaders 0
        tolerances 0
        mismatches 0
        layer-mismatches 0
        overrides 0
        errors nil
        xref-names nil)
  (vlax-for block blocks
    (if (cnd:is-xref-block-p block)
      (setq xref-names (cons (vla-get-Name block) xref-names))
      (vlax-for object block
        (if (cnd:dimension-reference-p object)
          (progn
            (setq total (1+ total))
            (setq object-name (vla-get-ObjectName object))
            (cond
              ((wcmatch object-name "AcDb*Dimension")
                (setq dimensions (1+ dimensions)))
              ((= object-name "AcDbLeader")
                (setq leaders (1+ leaders)))
              ((= object-name "AcDbFcf")
                (setq tolerances (1+ tolerances)))
            )
            (setq style-result
              (vl-catch-all-apply 'vla-get-StyleName (list object))
            )
            (if
              (or
                (vl-catch-all-error-p style-result)
                (/= (strcase style-result) (strcase target-style))
              )
              (setq mismatches (1+ mismatches))
            )
            (setq layer-result
              (vl-catch-all-apply 'vla-get-Layer (list object))
            )
            (if
              (or
                (vl-catch-all-error-p layer-result)
                (/= (strcase layer-result) (strcase target-layer))
              )
              (setq layer-mismatches (1+ layer-mismatches))
            )
            (setq ename-result
              (vl-catch-all-apply 'vlax-vla-object->ename (list object))
            )
            (if (vl-catch-all-error-p ename-result)
              (setq errors
                (cons
                  (strcat
                    (vla-get-Name block)
                    "|"
                    (vla-get-Handle object)
                    "|Cannot read entity name."
                  )
                  errors
                )
              )
              (if (cnd:has-dstyle-override-p ename-result)
                (setq overrides (1+ overrides))
              )
            )
          )
        )
      )
    )
  )
  (list
    (cons 'total total)
    (cons 'dimensions dimensions)
    (cons 'leaders leaders)
    (cons 'tolerances tolerances)
    (cons 'mismatches mismatches)
    (cons 'layer-mismatches layer-mismatches)
    (cons 'overrides overrides)
    (cons 'errors (reverse errors))
    (cons 'xref-names
      (vl-sort
        (vl-remove-if 'null xref-names)
        '(lambda (a b) (< (strcase a) (strcase b)))
      )
    )
  )
)

(defun cnd:numeric-equal-p (a b)
  (equal (float a) (float b) 0.0000001)
)

(defun cnd:configure-work-style (document iso-style work-style text-height arrow-size overall-scale / text-style-name text-style)
  (vla-CopyFrom work-style iso-style)
  (vla-put-ActiveDimStyle document work-style)
  (setvar "DIMTXT" text-height)
  (setvar "DIMASZ" arrow-size)
  (setvar "DIMSCALE" overall-scale)
  (setvar "DIMCLRD" 256)
  (setvar "DIMCLRE" 256)
  (setvar "DIMCLRT" 256)
  (setvar "DIMDSEP" ".")
  (setvar "DIMDEC" 1)
  (setq text-style-name (getvar "DIMTXSTY"))
  (setq text-style
    (cnd:item (vla-get-TextStyles document) text-style-name)
  )
  (if (null text-style)
    (cnd:raise (strcat "Dimension text style not found: " text-style-name))
  )
  (vla-put-Height text-style 0.0)
  (vla-CopyFrom work-style document)
  (vla-put-ActiveDimStyle document iso-style)
  (vla-put-ActiveDimStyle document work-style)
  text-style-name
)

(defun cnd:copy-work-to-final (document work-style final-style)
  (vla-CopyFrom final-style work-style)
  (vla-put-ActiveDimStyle document work-style)
  (vla-put-ActiveDimStyle document final-style)
  T
)

(defun cnd:style-check (document style text-height arrow-size overall-scale / errors text-style-name text-style text-style-height)
  (setq errors nil)
  (vla-put-ActiveDimStyle document style)
  (if (not (cnd:numeric-equal-p (getvar "DIMTXT") text-height))
    (setq errors (cons "DIMTXT" errors))
  )
  (if (not (cnd:numeric-equal-p (getvar "DIMASZ") arrow-size))
    (setq errors (cons "DIMASZ" errors))
  )
  (if (not (cnd:numeric-equal-p (getvar "DIMSCALE") overall-scale))
    (setq errors (cons "DIMSCALE" errors))
  )
  (if (/= (getvar "DIMCLRD") 256)
    (setq errors (cons "DIMCLRD" errors))
  )
  (if (/= (getvar "DIMCLRE") 256)
    (setq errors (cons "DIMCLRE" errors))
  )
  (if (/= (getvar "DIMCLRT") 256)
    (setq errors (cons "DIMCLRT" errors))
  )
  (if (/= (getvar "DIMDSEP") ".")
    (setq errors (cons "DIMDSEP" errors))
  )
  (if (/= (getvar "DIMDEC") 1)
    (setq errors (cons "DIMDEC" errors))
  )
  (setq text-style-name (getvar "DIMTXSTY"))
  (setq text-style
    (cnd:item (vla-get-TextStyles document) text-style-name)
  )
  (if text-style
    (progn
      (setq text-style-height (vla-get-Height text-style))
      (if (not (cnd:numeric-equal-p text-style-height 0.0))
        (setq errors (cons "TEXT_STYLE_HEIGHT" errors))
      )
    )
    (progn
      (setq text-style-height -1.0)
      (setq errors (cons "TEXT_STYLE_MISSING" errors))
    )
  )
  (list
    (cons 'errors (reverse errors))
    (cons 'dimtxt (getvar "DIMTXT"))
    (cons 'dimasz (getvar "DIMASZ"))
    (cons 'dimscale (getvar "DIMSCALE"))
    (cons 'dimclrd (getvar "DIMCLRD"))
    (cons 'dimclre (getvar "DIMCLRE"))
    (cons 'dimclrt (getvar "DIMCLRT"))
    (cons 'dimdsep (getvar "DIMDSEP"))
    (cons 'dimdec (getvar "DIMDEC"))
    (cons 'text-style text-style-name)
    (cons 'text-style-height text-style-height)
  )
)

(defun cnd:style-xref-dependent-p (name / ename data flags)
  (setq ename (tblobjname "DIMSTYLE" name))
  (if ename
    (progn
      (setq data (entget ename))
      (setq flags (cdr (assoc 70 data)))
      (and flags (/= 0 (logand flags 16)))
    )
    nil
  )
)

(defun cnd:member-ci-p (name names / found)
  (setq found nil)
  (foreach candidate names
    (if (= (strcase name) (strcase candidate))
      (setq found T)
    )
  )
  found
)

(defun cnd:dimension-style-names (document / names)
  (setq names nil)
  (vlax-for style (vla-get-DimStyles document)
    (setq names (cons (vla-get-Name style) names))
  )
  (vl-sort names '(lambda (a b) (< (strcase a) (strcase b))))
)

(defun cnd:delete-local-styles-except (document keep-names / pass names deleted result count)
  (setq pass 0
        deleted nil)
  (while (< pass 10)
    (setq count 0)
    (setq names (cnd:dimension-style-names document))
    (foreach name names
      (if
        (and
          (not (cnd:member-ci-p name keep-names))
          (not (cnd:style-xref-dependent-p name))
        )
        (progn
          (setq result
            (vl-catch-all-apply
              'vla-Delete
              (list (cnd:item (vla-get-DimStyles document) name))
            )
          )
          (if (not (vl-catch-all-error-p result))
            (progn
              (setq deleted (cons name deleted))
              (setq count (1+ count))
            )
          )
        )
      )
    )
    (setq pass (1+ pass))
    (if (= count 0)
      (setq pass 10)
    )
  )
  (reverse deleted)
)

(defun cnd:remaining-style-groups (document final-name / local-styles xref-styles)
  (setq local-styles nil
        xref-styles nil)
  (foreach name (cnd:dimension-style-names document)
    (if (/= (strcase name) (strcase final-name))
      (if (cnd:style-xref-dependent-p name)
        (setq xref-styles (cons name xref-styles))
        (setq local-styles (cons name local-styles))
      )
      (setq local-styles (cons name local-styles))
    )
  )
  (list
    (cons 'local-styles
      (vl-sort local-styles
        '(lambda (a b) (< (strcase a) (strcase b)))))
    (cons 'xref-styles
      (vl-sort xref-styles
        '(lambda (a b) (< (strcase a) (strcase b)))))
  )
)

(defun cnd:assert-scan-clean (scan phase)
  (if (> (cdr (assoc 'mismatches scan)) 0)
    (cnd:raise
      (strcat
        phase
        " style mismatch count: "
        (itoa (cdr (assoc 'mismatches scan)))
      )
    )
  )
  (if (> (cdr (assoc 'layer-mismatches scan)) 0)
    (cnd:raise
      (strcat
        phase
        " layer mismatch count: "
        (itoa (cdr (assoc 'layer-mismatches scan)))
      )
    )
  )
  (if (> (cdr (assoc 'overrides scan)) 0)
    (cnd:raise
      (strcat
        phase
        " override count: "
        (itoa (cdr (assoc 'overrides scan)))
      )
    )
  )
  (if (cdr (assoc 'errors scan))
    (cnd:raise
      (strcat
        phase
        " scan errors: "
        (cnd:join (cdr (assoc 'errors scan)) ";;")
      )
    )
  )
  T
)

(defun cnd:assert-style-clean (check phase)
  (if (cdr (assoc 'errors check))
    (cnd:raise
      (strcat
        phase
        " style check errors: "
        (cnd:join (cdr (assoc 'errors check)) ";;")
      )
    )
  )
  T
)

(defun cnd:execute-normalize (text-height arrow-size overall-scale work-name final-name layer-name / document styles final-style work-style work-text-style work-apply work-scan work-check deleted-first deleted-final final-apply final-scan final-check groups local-styles xref-styles)
  (setq *cnd-phase* "OPEN_DOCUMENT")
  (setq document
    (vla-get-ActiveDocument (vlax-get-acad-object))
  )
  (setq styles (vla-get-DimStyles document))
  (setq final-style (cnd:item styles final-name))
  (if (null final-style)
    (cnd:raise (strcat "Required local dimension style is missing: " final-name))
  )

  (setq *cnd-phase* "ENSURE_DIM_LAYER")
  (cnd:ensure-layer document layer-name)

  (setq work-style (cnd:item styles work-name))
  (if (null work-style)
    (setq work-style (vla-Add styles work-name))
  )

  (setq *cnd-phase* "CONFIGURE_MHSA_DIM")
  (setq work-text-style
    (cnd:configure-work-style
      document
      final-style
      work-style
      text-height
      arrow-size
      overall-scale
    )
  )

  (setq *cnd-phase* "APPLY_MHSA_DIM")
  (setq work-apply
    (cnd:apply-style-everywhere document work-name layer-name)
  )
  (if (cdr (assoc 'errors work-apply))
    (cnd:raise
      (strcat
        "Working-style apply errors: "
        (cnd:join (cdr (assoc 'errors work-apply)) ";;")
      )
    )
  )
  (setq *cnd-phase* "VERIFY_MHSA_DIM_REFERENCES")
  (setq work-scan
    (cnd:scan-references document work-name layer-name)
  )
  (setq *cnd-phase* "VERIFY_MHSA_DIM_STYLE")
  (setq work-check
    (cnd:style-check
      document
      work-style
      text-height
      arrow-size
      overall-scale
    )
  )
  (cnd:assert-scan-clean work-scan "MHSA-DIM")
  (cnd:assert-style-clean work-check "MHSA-DIM")

  (setq *cnd-phase* "DELETE_INTERMEDIATE_STYLES")
  (setq deleted-first
    (cnd:delete-local-styles-except
      document
      (list final-name work-name)
    )
  )

  (setq *cnd-phase* "COPY_MHSA_TO_ISO25")
  (cnd:copy-work-to-final document work-style final-style)
  (setq *cnd-phase* "APPLY_ISO25")
  (setq final-apply
    (cnd:apply-style-everywhere document final-name layer-name)
  )
  (if (cdr (assoc 'errors final-apply))
    (cnd:raise
      (strcat
        "Final-style apply errors: "
        (cnd:join (cdr (assoc 'errors final-apply)) ";;")
      )
    )
  )

  (setq *cnd-phase* "DELETE_FINAL_STYLES")
  (vla-put-ActiveDimStyle document final-style)
  (setq deleted-final
    (cnd:delete-local-styles-except
      document
      (list final-name)
    )
  )

  (setq *cnd-phase* "VERIFY_ISO25_REFERENCES")
  (setq final-scan
    (cnd:scan-references document final-name layer-name)
  )
  (setq *cnd-phase* "VERIFY_ISO25_STYLE")
  (setq final-check
    (cnd:style-check
      document
      final-style
      text-height
      arrow-size
      overall-scale
    )
  )
  (cnd:assert-scan-clean final-scan "ISO-25")
  (cnd:assert-style-clean final-check "ISO-25")

  (setq *cnd-phase* "VERIFY_REMAINING_STYLES")
  (setq groups (cnd:remaining-style-groups document final-name))
  (setq local-styles (cdr (assoc 'local-styles groups)))
  (setq xref-styles (cdr (assoc 'xref-styles groups)))
  (if
    (or
      (/= (length local-styles) 1)
      (/= (strcase (car local-styles)) (strcase final-name))
    )
    (cnd:raise
      (strcat
        "Unexpected local dimension styles remain: "
        (cnd:join local-styles ";;")
      )
    )
  )

  (setq *cnd-phase* "REGEN")
  (vla-Regen document 1)
  (list
    (cons "MESSAGE" "Normalization and in-memory verification succeeded.")
    (cons "TOTAL_REFERENCES" (cdr (assoc 'total final-scan)))
    (cons "DIMENSIONS" (cdr (assoc 'dimensions final-scan)))
    (cons "LEADERS" (cdr (assoc 'leaders final-scan)))
    (cons "TOLERANCES" (cdr (assoc 'tolerances final-scan)))
    (cons "STYLE_MISMATCH_COUNT" (cdr (assoc 'mismatches final-scan)))
    (cons "LAYER_MISMATCH_COUNT"
      (cdr (assoc 'layer-mismatches final-scan)))
    (cons "OVERRIDE_COUNT" (cdr (assoc 'overrides final-scan)))
    (cons "DELETED_STYLE_COUNT"
      (length (append deleted-first deleted-final)))
    (cons "LOCAL_STYLES" (cnd:join local-styles ";;"))
    (cons "XREF_STYLES" (cnd:join xref-styles ";;"))
    (cons "XREF_NAMES"
      (cnd:join (cdr (assoc 'xref-names final-scan)) ";;"))
    (cons "DIMTXT" (cdr (assoc 'dimtxt final-check)))
    (cons "DIMASZ" (cdr (assoc 'dimasz final-check)))
    (cons "DIMSCALE" (cdr (assoc 'dimscale final-check)))
    (cons "DIMCLRD" (cdr (assoc 'dimclrd final-check)))
    (cons "DIMCLRE" (cdr (assoc 'dimclre final-check)))
    (cons "DIMCLRT" (cdr (assoc 'dimclrt final-check)))
    (cons "DIMDSEP" (cdr (assoc 'dimdsep final-check)))
    (cons "DIMDEC" (cdr (assoc 'dimdec final-check)))
    (cons "DIMENSION_LAYER" layer-name)
    (cons "TEXT_STYLE" (cdr (assoc 'text-style final-check)))
    (cons "TEXT_STYLE_HEIGHT"
      (cdr (assoc 'text-style-height final-check)))
    (cons "WORK_TEXT_STYLE" work-text-style)
  )
)

(defun cnd:execute-verify (text-height arrow-size overall-scale final-name layer-name / document styles final-style scan check groups local-styles xref-styles)
  (setq *cnd-phase* "POST_SAVE_OPEN")
  (setq document
    (vla-get-ActiveDocument (vlax-get-acad-object))
  )
  (setq styles (vla-get-DimStyles document))
  (setq final-style (cnd:item styles final-name))
  (if (null final-style)
    (cnd:raise (strcat "Required final style is missing: " final-name))
  )
  (if (null (cnd:item (vla-get-Layers document) layer-name))
    (cnd:raise (strcat "Required dimension layer is missing: " layer-name))
  )
  (setq *cnd-phase* "POST_SAVE_VERIFY_REFERENCES")
  (setq scan
    (cnd:scan-references document final-name layer-name)
  )
  (setq *cnd-phase* "POST_SAVE_VERIFY_STYLE")
  (setq check
    (cnd:style-check
      document
      final-style
      text-height
      arrow-size
      overall-scale
    )
  )
  (cnd:assert-scan-clean scan "Post-save ISO-25")
  (cnd:assert-style-clean check "Post-save ISO-25")

  (setq *cnd-phase* "POST_SAVE_VERIFY_REMAINING_STYLES")
  (setq groups (cnd:remaining-style-groups document final-name))
  (setq local-styles (cdr (assoc 'local-styles groups)))
  (setq xref-styles (cdr (assoc 'xref-styles groups)))
  (if
    (or
      (/= (length local-styles) 1)
      (/= (strcase (car local-styles)) (strcase final-name))
    )
    (cnd:raise
      (strcat
        "Unexpected local dimension styles remain after save: "
        (cnd:join local-styles ";;")
      )
    )
  )

  (list
    (cons "MESSAGE" "Post-save verification succeeded.")
    (cons "TOTAL_REFERENCES" (cdr (assoc 'total scan)))
    (cons "DIMENSIONS" (cdr (assoc 'dimensions scan)))
    (cons "LEADERS" (cdr (assoc 'leaders scan)))
    (cons "TOLERANCES" (cdr (assoc 'tolerances scan)))
    (cons "STYLE_MISMATCH_COUNT" (cdr (assoc 'mismatches scan)))
    (cons "LAYER_MISMATCH_COUNT"
      (cdr (assoc 'layer-mismatches scan)))
    (cons "OVERRIDE_COUNT" (cdr (assoc 'overrides scan)))
    (cons "LOCAL_STYLES" (cnd:join local-styles ";;"))
    (cons "XREF_STYLES" (cnd:join xref-styles ";;"))
    (cons "XREF_NAMES"
      (cnd:join (cdr (assoc 'xref-names scan)) ";;"))
    (cons "DIMTXT" (cdr (assoc 'dimtxt check)))
    (cons "DIMASZ" (cdr (assoc 'dimasz check)))
    (cons "DIMSCALE" (cdr (assoc 'dimscale check)))
    (cons "DIMCLRD" (cdr (assoc 'dimclrd check)))
    (cons "DIMCLRE" (cdr (assoc 'dimclre check)))
    (cons "DIMCLRT" (cdr (assoc 'dimclrt check)))
    (cons "DIMDSEP" (cdr (assoc 'dimdsep check)))
    (cons "DIMDEC" (cdr (assoc 'dimdec check)))
    (cons "DIMENSION_LAYER" layer-name)
    (cons "TEXT_STYLE" (cdr (assoc 'text-style check)))
    (cons "TEXT_STYLE_HEIGHT"
      (cdr (assoc 'text-style-height check)))
  )
)

(defun cnd-normalize (report-path output-path text-height arrow-size overall-scale work-name final-name layer-name / result save-result)
  (setq *cnd-phase* "NORMALIZE_START")
  (setq *cnd-error-message* nil)
  (setq result
    (vl-catch-all-apply
      'cnd:execute-normalize
      (list
        text-height
        arrow-size
        overall-scale
        work-name
        final-name
        layer-name
      )
    )
  )
  (if (vl-catch-all-error-p result)
    (cnd:write-report
      report-path
      (list
        (cons "STATUS" "FAILURE")
        (cons "SAVED" "FALSE")
        (cons "PHASE" *cnd-phase*)
        (cons "MESSAGE"
          (if *cnd-error-message*
            *cnd-error-message*
            (vl-catch-all-error-message result)
          )
        )
      )
    )
    (progn
      (setq *cnd-phase* "SAVE")
      (setq save-result
        (vl-catch-all-apply
          'vla-SaveAs
          (list
            (vla-get-ActiveDocument (vlax-get-acad-object))
            output-path
          )
        )
      )
      (if (vl-catch-all-error-p save-result)
        (cnd:write-report
          report-path
          (list
            (cons "STATUS" "FAILURE")
            (cons "SAVED" "FALSE")
            (cons "PHASE" *cnd-phase*)
            (cons "MESSAGE"
              (strcat
                "Save failed: "
                (vl-catch-all-error-message save-result)
              )
            )
          )
        )
        (cnd:write-report
          report-path
          (append
            (list
              (cons "STATUS" "SUCCESS")
              (cons "SAVED" "TRUE")
              (cons "PHASE" "COMPLETE")
              (cons "OUTPUT_PATH" output-path)
            )
            result
          )
        )
      )
    )
  )
  (princ)
)

(defun cnd-verify (report-path text-height arrow-size overall-scale final-name layer-name / result)
  (setq *cnd-phase* "VERIFY_START")
  (setq *cnd-error-message* nil)
  (setq result
    (vl-catch-all-apply
      'cnd:execute-verify
      (list
        text-height
        arrow-size
        overall-scale
        final-name
        layer-name
      )
    )
  )
  (if (vl-catch-all-error-p result)
    (cnd:write-report
      report-path
      (list
        (cons "STATUS" "FAILURE")
        (cons "SAVED" "FALSE")
        (cons "PHASE" *cnd-phase*)
        (cons "MESSAGE"
          (if *cnd-error-message*
            *cnd-error-message*
            (vl-catch-all-error-message result)
          )
        )
      )
    )
    (cnd:write-report
      report-path
      (append
        (list
          (cons "STATUS" "SUCCESS")
          (cons "SAVED" "FALSE")
          (cons "PHASE" "POST_SAVE_COMPLETE")
        )
        result
      )
    )
  )
  (princ)
)

(princ)
