;;; emidje.el --- Test runner and report viewer for Midje -*- lexical-binding: t -*-

;; Author: Alan Ghelardi <alan.ghelardi@nubank.com.br>
;; Maintainer: Alan Ghelardi <alan.ghelardi@nubank.com.br>
;; Version: 0.1.0-SNAPSHOT
;; Package-Requires: ((cider "0.17.0"))
;; Homepage: https://github.com/alan-ghelardi/emidje
;; Keywords: Cider, Clojure, Midje, tests

;;; Commentary:

;; Emidje is a Cider plugin that provides support to run Midje tests within Emacs.

;;; Code:

(require 'ansi-color)
(require 'cider)

(defface emidje-failure-face
  '((((class color) (background light))
     :background "orange red")
    (((class color) (background dark))
     :background "firebrick"))
  "Face for failed tests."
  :group 'emidje
  :package-version '(emidje . "0.1.0"))

(defface emidje-error-face
  '((((class color) (background light))
     :background "orange1")
    (((class color) (background dark))
     :background "orange4"))
  "Face for erring tests."
  :group 'emidje
  :package-version '(emidje . "0.1.0"))

(defface emidje-success-face
  '((((class color) (background light))
     :foreground "black"
     :background "green")
    (((class color) (background dark))
     :foreground "black"
     :background "green"))
  "Face for passing tests."
  :group 'emidje
  :package-version '(emidje . "0.1.0"))

(defface emidje-work-todo-face
  '((((class color) (background light))
     :background "yellow1")
    (((class color) (background dark))
     :background "yellow4"))
  "Face for future facts."
  :group 'emidje
  :package-version '(emidje . "0.1.0"))

(defcustom emidje-inject-nrepl-middleware-at-jack-in t
  "When nil, do not inject `midje-nrepl' at `cider-jack-in' time."
  :group 'emidje
  :type 'boolean
  :package-version '(emidje . "0.1.0"))

(defcustom emidje-infer-test-ns-function 'emidje-default-infer-test-ns-function
  "Function to infer the test namespace."
  :type 'symbol
  :group 'emidje
  :package-version '(emidje . "0.1.0"))

(defun emidje-default-infer-test-ns-function (current-ns)
  "Default function for inferring the namespace to be tested.
Apply the Leiningen convention of appending the suffix `-test' to CURRENT-NS."
  (let ((suffix "-test"))
    (if (string-suffix-p suffix current-ns)
        current-ns
      (concat current-ns suffix))))

(defcustom emidje-load-facts-on-eval nil
  "When set to nil, Midje facts won't be loaded on operations that cause the evaluation of Clojure forms like `eval' and `load-file'."
  :type 'boolean
  :group 'emidje
  :package-version '(emidje . "0.1.0"))

(defcustom emidje-show-full-test-summary t
  "When set to t, Emidje shows a full test summary on the message buffer.
Set to nil if you prefer to see a shorter version of test summaries."
  :type 'boolean
  :group 'emidje
  :package-version '(emidje . "0.1.0"))

(defcustom emidje-suppress-nrepl-middleware-warnings nil
  "When set to t, no nREPL middleware warnings are shown on the REPL."
  :type 'boolean
  :group 'emidje
  :package-version '(emidje . "0.1.0"))

(defconst emidje-evaluation-operations (list "eval" "load-file")
  "List of nREPL operations that cause the evaluation of Clojure forms.")

(defconst emidje-test-report-buffer "*midje-test-report*"
  "The title of test report buffer.")

(defvar emidje-supported-operations
  '((:version . "midje-nrepl-version")
    (:format-tabular . "midje-format-tabular")
    (:project . "midje-test-all")
    (:ns . "midje-test-ns")
    (:test-at-point . "midje-test")
    (:retest . "midje-retest")
    (:test-stacktrace . "midje-test-stacktrace")))

(defun emidje-render-stacktrace (causes)
  "Render the Cider error buffer with the given CAUSES."
  (cider-stacktrace-render
   (cider-popup-buffer cider-error-buffer
                       cider-auto-select-error-buffer
                       #'cider-stacktrace-mode)
   causes))

(defun emidje-handle-error-response (response)
  "Handle the error RESPONSE returned by `midje-nrepl'."
  (nrepl-dbind-response response (error-message exception status)
    (cond
     (error-message (user-error error-message))
     (exception (emidje-render-stacktrace exception))
     (t (user-error "Midje-nrepl returned the following status: %st" (mapconcat #'identity status ", "))))))

(defun emidje-handle-nrepl-response (handler-function response)
  "Handle the nREPL RESPONSE by delegating to the specified HANDLER-FUNCTION.
If RESPONSE contains the `error' status, delegate to `emidje-handle-error-response'."
  (nrepl-dbind-response response (status)
    (if (seq-contains status "error")
        (emidje-handle-error-response response)
      (apply handler-function (list response)))))

(defun emidje-send-request (operation-type &optional params callback)
  "Send a request to nREPL middleware.
Make an asynchronous request when CALLBACK is set and a synchronous one otherwise."
  (cider-ensure-connected)
  (let* ((op (cdr (assq operation-type emidje-supported-operations)))
         (message (thread-last (or params ())
                    (seq-map (lambda (value)
                               (if (symbolp value)
                                   (symbol-name value)
                                 value)))
                    (append `("op" ,op)))))
    (if callback
        (cider-nrepl-send-request message (apply-partially #'emidje-handle-nrepl-response callback))
      (thread-last (cider-nrepl-send-sync-request message)
        (emidje-handle-nrepl-response #'identity)))))

(defun emidje-package-version ()
  "Get Emidje's current version from the package header."
  (let ((version-regex "^\\([0-9]+\.[0-9]+\.[0-9]+\\)\\(.*\\)$")
        (version (pkg-info-version-info 'emidje)))
    (if (not (string-match version-regex version))
        version
      (concat (match-string 1 version) "-" (upcase (match-string 2 version))))))

(defun emidje-show-warning-on-repl (message &rest args)
  "If `emidje-suppress-nrepl-middleware-warnings' isn't set to t, show the MESSAGE on the Cider's REPL buffer."
  (unless emidje-suppress-nrepl-middleware-warnings
    (cider-repl-emit-interactive-stderr
     (apply #'format (concat "WARNING: " message
                             "\nYou can mute this warning by changing the variable emidje-suppress-nrepl-middleware-warnings to t.")
            args))))

(defun emidje-check-nrepl-middleware-version ()
  "Check whether `emidje' and `midje-nrepl' versions are in sync.
Show warning messages on Cider's REPL when applicable."
  (let ((emidje-version (emidje-package-version))
        (midje-nrepl-version (nrepl-dict-get-in (emidje-send-request :version) `("midje-nrepl" "version-string"))))
    (cond
     ((not midje-nrepl-version)
      (emidje-show-warning-on-repl "midje-nrepl isn't in your classpath; Emidje keybindings won't work!
 You can either start this REPL via cider-jack-in or add midje-nrepl to your profile.clj dependencies."))
     ((not (string-equal emidje-version midje-nrepl-version))
      (emidje-show-warning-on-repl "Emidje and midje-nrepl are out of sync. Things will break!
Their versions are %s and %s, respectively.
Please, consider updating the midje-nrepl version in your profile.clj to %s or start the REPL via cider-jack-in." emidje-version midje-nrepl-version emidje-version)))))

(defun emidje-inject-nrepl-middleware ()
  "Add midje-nrepl to the Cider's list of Lein plugins."
  (when (and (boundp 'cider-jack-in-lein-plugins)
             emidje-inject-nrepl-middleware-at-jack-in)
    (add-to-list 'cider-jack-in-lein-plugins `("midje-nrepl" ,(emidje-package-version)) t)))

;;;###autoload
(eval-after-load 'cider
  '(emidje-inject-nrepl-middleware))

(add-hook 'cider-connected-hook #'emidje-check-nrepl-middleware-version)

(defun emidje-insert-section (content)
  "Insert CONTENT in the current buffer's position.
Treat ansi colors appropriately."
  (let* ((begin (point))
         (lines (if (stringp content)
                    (split-string content "\n")
                  (append content '("\n")))))
    (thread-last lines
      (seq-map                         #'cider-font-lock-as-clojure)
      insert-rectangle)
    (ansi-color-apply-on-region begin (point))
    (beginning-of-line)))

(defun emidje-render-one-test-result (result)
  "Render one test RESULT in the current buffer's position."
  (nrepl-dbind-response result (context expected actual error message type)
    (cl-flet ((insert-label (text)
                            (cider-insert (format "%8s: " text) 'font-lock-comment-face)))
      (cider-propertize-region (cider-intern-keys (cdr result))
        (let ((begin (point))
              (type-face (cider-test-type-simple-face type))
              (bg `(:background ,cider-test-items-background-color)))
          (if (equal type "to-do")
              (cider-insert "Work To Do " 'emidje-work-todo-face nil)
            (cider-insert (capitalize type) type-face nil " in "))
          (dolist (text context)
            (cider-insert text 'font-lock-doc-face t))
          (insert "\n")
          (when expected
            (insert-label "expected")
            (emidje-insert-section expected)
            (insert "\n"))
          (when actual
            (insert-label "actual")
            (emidje-insert-section actual)
            (insert "\n"))
          (unless (seq-empty-p message)
            (insert-label "Checker said about the reason")
            (emidje-insert-section message))
          (when error
            (insert-label "error")
            (insert-text-button error
                                'follow-link t
                                'action '(lambda (_button) (emidje-show-test-stacktrace))
                                'help-echo "View causes and stacktrace")
            (insert "\n\n"))
          (overlay-put (make-overlay begin (point)) 'font-lock-face bg))))))

(defun emidje-count-non-passing-tests (results)
  "Return the number of non-passing tests from the RESULTS dict."
  (seq-count (lambda (result)
               (let* ((type (nrepl-dict-get result "type")))
                 (or (equal type "error")
                     (equal type "fail")))) results))

(defun emidje-get-displayable-results (results)
  "Filter RESULTS by returning a new dict without passing tests."
  (seq-filter (lambda (result)
                (not (equal (nrepl-dict-get result "type") "pass")))
              results))

(defun emidje-render-test-results (results-dict)
  "Iterate over RESULTS-DICT and render all test results."
  (cider-insert "Results" 'bold t "\n")
  (nrepl-dict-map (lambda (ns results)
                    (let* ((displayable-results (emidje-get-displayable-results results))
                           (problems (emidje-count-non-passing-tests displayable-results)))
                      (when (> problems 0)
                        (insert (format "%s\n%d non-passing tests:\n\n"
                                        (cider-propertize ns 'ns) problems)))
                      (dolist (result displayable-results)
                        (emidje-render-one-test-result result)))
                    ) results-dict))

(defun emidje-render-list-of-namespaces (results)
  "Render a list of tested namespaces in the current buffer.
Propertize each namespace appropriately in order to allow users to jump to the file in question."
  (cl-flet ((file-path-for (namespace)
                           (thread-first results
                             (nrepl-dict-get namespace)
                             car
                             (nrepl-dict-get "file"))))
    (dolist (namespace (nrepl-dict-keys results))
      (insert (propertize (cider-propertize namespace 'ns)
                          'file (file-path-for namespace)) "\n")
      (insert "\n"))))

(defun emidje-render-test-summary (summary)
  "Render the test summary in the current buffer's position."
  (nrepl-dbind-response summary (check error fact fail ns pass to-do)
    (insert (format "Checked %d namespaces\n" ns))
    (insert (format "Ran %d checks in %d facts\n" check fact))
    (unless (zerop fail)
      (cider-insert (format "%d failures" fail) 'emidje-failure-face t))
    (unless (zerop error)
      (cider-insert (format "%d errors" error) 'emidje-error-face t))
    (unless (zerop to-do)
      (cider-insert (format "%d to do" to-do) 'emidje-work-todo-face t))
    (when (zerop (+ fail error))
      (cider-insert (format "%d passed" pass) 'emidje-success-face t))
    (insert "\n")))

(defun emidje-kill-test-report-buffer ()
  "Kill the test report buffer if one exists."
  (when-let ((buffer (get-buffer emidje-test-report-buffer)))
    (kill-buffer buffer)))

(defun emidje-tests-passed-p (summary)
  "Return t if all tests passed."
  (nrepl-dbind-response summary (fail error)
    (zerop (+ fail error))))

(defun emidje-render-test-report (results summary)
  "Render the test report if there are erring and/or failing tests.
If the tests were successful and there's a test report buffer rendered, kill it."
  (if (emidje-tests-passed-p summary)
      (emidje-kill-test-report-buffer)
    (with-current-buffer (or (get-buffer emidje-test-report-buffer)
                             (cider-popup-buffer emidje-test-report-buffer t))
      (emidje-report-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (cider-insert "Test Summary" 'bold t "\n")
        (emidje-render-list-of-namespaces results)
        (emidje-render-test-summary summary)
        (emidje-render-test-results results)
        (goto-char (point-min))))))

(defun emidje-summarize-test-results (operation-type namespace summary)
  "Return a string summarizing test results according to user's preferences."
  (nrepl-dbind-response summary (check fact error fail pass to-do)
    (let ((possible-test-ns (if (equal operation-type :ns)
                                (format "%s: " namespace)
                              ""))
          (possible-future-facts (if (zerop to-do)
                                     ""
                                   (format ", %d to do" to-do))))
      (cond
       (emidje-show-full-test-summary (format "%sRan %d checks in %d facts. %d failures, %d errors%s." possible-test-ns check fact fail error possible-future-facts))
       ((zerop (+ error fail)) (format "All checks (%d) succeeded." check))
       (t (format "%d checks failed, but %d succeeded." (+ error fail) pass))))))

(defun emidje-echo-summary (operation-type namespace summary)
  "Show a test summary on the message buffer."
  (nrepl-dbind-response summary (check fail error)
    (if (and (zerop check) (zerop error))
        (message (propertize "No facts were checked. Is that what you wanted?"
                             'face 'emidje-error-face))
      (let ((face (cond
                   ((not (zerop error)) 'emidje-error-face)
                   ((not (zerop fail)) 'emidje-failure-face)
                   (t 'emidje-success-face))))
        (message (propertize
                  (emidje-summarize-test-results operation-type namespace summary) 'face face))))))

(defun emidje-read-test-description-at-point ()
  (ignore-errors
    (save-excursion (down-list)
                    (forward-sexp 2)
                    (let ((possible-description (sexp-at-point)))
                      (if (stringp possible-description)
                          (format "\"%s\" " possible-description)
                        "")))))

(defun emidje-echo-running-tests (op-type args)
  (let* ((ns (plist-get args 'ns))
         (test-description (emidje-read-test-description-at-point)))
    (pcase op-type
      (:project (message "Running tests in all project namespaces..."))
      (:ns (message "Running tests in %s..." (cider-propertize ns 'ns)))
      (:test-at-point (message "Running test %sin %s..." (cider-propertize test-description 'bold) (cider-propertize ns 'ns)))
      (      :retest (message "Re-running non-passing tests...")))))

(defun emidje-send-test-request (operation-type &optional message)
  "Send the test message asynchronously and show the test report when applicable."
  (emidje-echo-running-tests operation-type message)
  (emidje-send-request operation-type message
                       (lambda (response)
                         (nrepl-dbind-response response (results summary)
                           (when (and results summary)
                             (emidje-echo-summary operation-type (plist-get message 'ns) summary)
                             (emidje-render-test-report results summary))))))

(defun emidje-run-all-tests ()
  "Run tests defined in all project namespaces."
  (interactive)
  (emidje-send-test-request :project))

(defun emidje-current-test-ns ()
  "Return the test namespace that corresponds to the current Clojure namespace context."
  (let ((current-ns (cider-current-ns t)))
    (if (string-equal current-ns "user")
        (user-error "No namespace to be tested in the current context")
      (funcall emidje-infer-test-ns-function current-ns))))

(defun emidje-run-ns-tests ()
  "Run all tests in the current Clojure namespace context."
  (interactive)
  (let ((namespace (emidje-current-test-ns)))
    (emidje-send-test-request :ns `(ns ,namespace))))

(defun emidje-run-test-at-point ()
  "Run test at point.
Test means facts, fact, tabular or any Clojure form containing any of those."
  (interactive)
  (let* ((ns (cider-current-ns t))
         (sexp (cider-sexp-at-point))
         (line-number (line-number-at-pos)))
    (emidje-send-test-request :test-at-point `(ns ,ns
                                                  source ,sexp
                                                  line ,line-number))))

(defun emidje-re-run-non-passing-tests ()
  "Re-run tests that didn't pass in the last execution."
  (interactive)
  (emidje-send-test-request :retest))

(defun emidje-show-test-report ()
  "Show the test report buffer, if one exists."
  (interactive)
  (if-let (test-report-buffer (get-buffer emidje-test-report-buffer))
      (switch-to-buffer test-report-buffer)
    (user-error "No test report buffer")))

(defun emidje-send-format-request (sexpr)
  "Send a format request with the specified sexpr to nREPL middleware.
Return the formatted sexpr."
  (thread-first
      (emidje-send-request :format-tabular `(code ,sexpr))
    (nrepl-dict-get "formatted-code")))

(defun emidje-format-tabular ()
  "Format tabular fact at point."
  (interactive)
  (save-excursion
    (mark-sexp)
    (cider--format-region (region-beginning) (region-end) #'emidje-send-format-request)))

(defun emidje-instrumented-nrepl-send-request (original-function request &rest args)
  "Instrument nrepl-send-request and nrepl-send-sync-request functions by appending the parameter load-tests? to the request when applicable."
  (let* ((op (thread-last request
               (seq-drop-while (lambda (candidate)
                                 (not (equal candidate "op"))))
               cdr
               car))
         (request (if (and emidje-load-facts-on-eval (seq-contains emidje-evaluation-operations op))
                      (append request `("load-tests?" "true"))
                    request)))
    (apply original-function request args)))

;; Adivice functions
(advice-add'nrepl-send-request :around #'emidje-instrumented-nrepl-send-request)
(advice-add 'nrepl-send-sync-request :around #'emidje-instrumented-nrepl-send-request)

(defun emidje-toggle-load-facts-on-eval (&optional globally)
  "Toggles the value of emidje-load-facts-on-eval.
When called with an interactive prefix argument, toggles the default value of this variable globally."
  (interactive "P")
  (let ((switch (not emidje-load-facts-on-eval)))
    (if globally
        (setq-default emidje-load-facts-on-eval switch)
      (progn (make-local-variable 'emidje-load-facts-on-eval)
             (setq emidje-load-facts-on-eval switch)))
    (message "Turned %s %s %s"
             (if switch "on" "off")
             'emidje-load-facts-on-eval
             (if globally "globally" "locally"))))

(defun emidje-search-test-result-change (position search-function predicate-function)
  (let* ((position (funcall search-function position 'type))
         (test-result-type (when position
                             (get-text-property position 'type))))
    (cond
     ((not test-result-type) nil)
     ((funcall predicate-function test-result-type) position)
     (t (emidje-search-test-result-change position search-function predicate-function)))))

(defun emidje-move-point-to (direction test-result-type &optional friendly-result-name)
  (with-current-buffer (get-buffer emidje-test-report-buffer)
    (let* ((search-function (if (equal direction 'next) #'next-single-property-change #'previous-single-property-change))
           (predicate-function (if (equal test-result-type 'result) (apply-partially 'identity) (apply-partially 'equal (symbol-name test-result-type))))
           (position (emidje-search-test-result-change (point) search-function predicate-function)))
      (if position
          (goto-char position)
        (user-error "No %s %s in the test report" direction (or friendly-result-name test-result-type))))))

(defun emidje-next-result ()
  "Go to next test result in the test report buffer."
  (interactive)
  (emidje-move-point-to 'next 'result))

(defun emidje-previous-result ()
  "Go to previous test result in the test report buffer."
  (interactive)
  (emidje-move-point-to 'previous 'result))

(defun emidje-next-error ()
  "Go to next test error in the test report buffer."
  (interactive)
  (emidje-move-point-to 'next 'error))

(defun emidje-previous-error ()
  "Go to previous test error in the test report buffer."
  (interactive)
  (emidje-move-point-to 'previous 'error))

(defun emidje-next-failure ()
  "Go to next test failure in the test report buffer."
  (interactive)
  (emidje-move-point-to 'next 'fail "failure"))

(defun emidje-previous-failure ()
  "Go to previous test failure in the test report buffer."
  (interactive)
  (emidje-move-point-to 'previous 'fail "failure"))

(defun emidje-jump-to-definition (&optional other-window)
  "Jump to definition of namespace or test result at point.
If called interactively with a prefix argument, visit the file in question in a new window."
  (interactive "p")
  (let* ((file (or (get-text-property (point) 'file)
                   (user-error "Nothing to be visited here")))
         (line (or (get-text-property (point) 'line) 1))
         (buffer (cider--find-buffer-for-file file)))
    (if buffer
        (cider-jump-to buffer (cons line 1) other-window)
      (error "No source location"))))

(defun emidje-show-test-stacktrace-at (ns index)
  "Show the stacktrace for the error whose location within the report map is given by the ns and index."
  (let ((causes (list)))
    (emidje-send-request :test-stacktrace `(ns ,ns
                                               index ,index
                                               print-fn "clojure.lang/println")
                         (lambda (response)
                           (nrepl-dbind-response response (class status)
                             (cond (class  (setq causes (cons response causes)))
                                   (status (when causes
                                             (emidje-render-stacktrace (reverse causes))))))))))

(defun emidje-show-test-stacktrace ()
  "Show the stacktrace for the erring test at point."
  (interactive)
  (let ((ns    (get-text-property (point) 'ns))
        (index (get-text-property (point) 'index))
        (error (get-text-property (point) 'error)))
    (if (and error ns index)
        (emidje-show-test-stacktrace-at ns index)
      (message "No test error at point"))))

(defvar emidje-report-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n r") #'emidje-next-result)
    (define-key map (kbd "p r") #'emidje-previous-result)
    (define-key map (kbd "n e") #'emidje-next-error)
    (define-key map (kbd "p e") #'emidje-previous-error)
    (define-key map (kbd "n f") #'emidje-next-failure)
    (define-key map (kbd "p f") #'emidje-previous-failure)
    (define-key map (kbd "RET") #'emidje-jump-to-definition)
    map))

(defvar emidje-commands-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-j f") #'emidje-format-tabular)
    (define-key map (kbd "C-c C-j p") #'emidje-run-all-tests)
    (define-key map (kbd "C-c C-j n") #'emidje-run-ns-tests)
    (define-key map (kbd "C-c C-j t") #'emidje-run-test-at-point)
    (define-key map (kbd "C-c C-j r") #'emidje-re-run-non-passing-tests)
    (define-key map (kbd "C-c C-j s") #'emidje-show-test-report)
    map))

(define-derived-mode emidje-report-mode special-mode "Test Report"
  "Major mode for presenting Midje test results.

\\{emidje-report-mode-map}"
  (when cider-special-mode-truncate-lines
    (setq-local truncate-lines t))
  (setq-local electric-indent-chars nil))

(define-minor-mode emidje-mode
  "Provides a set of keybindings for interacting with Midje tests.

With a prefix argument ARG, enable emidje-mode if ARG
is positive, and disable it otherwise.  If called from Lisp,
enable the mode if ARG is omitted or nil.

\\{emidje-commands-map}"
  :lighter "emidje"
  :keymap emidje-commands-map)

(when (fboundp 'clojure-mode)
  (add-hook 'clojure-mode-hook #'emidje-mode t))

(when (fboundp 'cider-repl-mode)
  (add-hook 'cider-repl-mode-hook #'emidje-mode t))

(provide 'emidje)

;;; emidje.el ends here