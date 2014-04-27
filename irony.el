;;; irony.el --- C/C++ minor mode powered by libclang

;; Copyright (C) 2011-2014  Guillaume Papin

;; Author: Guillaume Papin <guillaume.papin@epitech.eu>
;; Version: 0.1.0
;; URL: https://github.com/Sarcasm/irony-mode
;; Compatibility: GNU Emacs 23.x, GNU Emacs 24.x
;; Keywords: c, convenience, tools
;; Package-Requires: ((cl-lib "0.5") (json "1.2"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; This file provides `irony-mode', a minor mode for C, C++ and Objective-C.

;;; Code:

(autoload 'irony-cdb-load-compile-options "irony-cdb")

(require 'cl-lib)

(autoload 'find-library-name "find-func")
(autoload 'lm-version "lisp-mnt")


;;
;; Compatibility
;;

(eval-and-compile

  ;; As seen in flycheck/magit
  ;;
  ;; Added in Emacs 24.3 (mirrors/emacs@b335efc3).
  (unless (fboundp 'setq-local)
    (defmacro setq-local (var val)
      "Set variable VAR to value VAL in current buffer."
      (list 'set (list 'make-local-variable (list 'quote var)) val)))

  ;; Added in Emacs 24.3 (mirrors/emacs@b335efc3).
  (unless (fboundp 'defvar-local)
    (defmacro defvar-local (var val &optional docstring)
      "Define VAR as a buffer-local variable with default value VAL.
Like `defvar' but additionally marks the variable as being
automatically buffer-local wherever it is set."
      (declare (debug defvar) (doc-string 3))
      (list 'progn (list 'defvar var val docstring)
            (list 'make-variable-buffer-local (list 'quote var)))))

  ) ;; eval-and-compile


;;
;; Customizable variables
;;

(defgroup irony nil
  "C/C++ minor mode powered by libclang."
  :group 'c)

(defcustom irony-lighter " Irony"
  "Text to display in the mode line when irony mode is on."
  :type 'string
  :group 'irony)

(defcustom irony-user-dir (locate-user-emacs-file "irony/")
  "Directory containing the Irony generated files.

The slash is expected at the end."
  :type 'directory
  :risky t
  :group 'irony)

(defcustom irony-supported-major-modes '(c++-mode
                                         c-mode
                                         objc-mode)
  "List of modes known to be compatible with Irony."
  :type '(repeat symbol)
  :group 'irony)

;;;###autoload
(defcustom irony-additional-clang-options nil
  "Additionnal command line options to pass down to libclang.

Please, do NOT use this variable to add header search paths, only
additional warnings or compiler options.

These compiler options will be prepended to the command line, in
order to not override the value coming from a compilation
database."
  :type '(repeat string)
  :options '("-Wdocumentation")
  :group 'irony)

;;;###autoload
(defcustom irony-clang-options-updated-hook nil
  "Normal hook run when the command line options have been updated.

This hook is run when the variables
`irony-header-search-directories',
`irony-clang-working-directory', etc, have been updated."
  ;; TODO: no etc...
  :type 'hook
  ;; TODO: :options '(ff-find-other-file/ff-search-directories)
  :group 'irony)

(defcustom irony-clang-lang-options-alist
  '((c++-mode  . "c++")
    (c-mode    . "c")
    (objc-mode . "objective-c"))
  "Association list of major-mode/lang-option to pass to clang."
  :type '(alist :key-type symbol :value-type string)
  :group 'irony)

(defcustom irony-cmake-executable "cmake"
  "The name or path of the CMake executable."
  :type 'string
  :group 'irony)

(defcustom irony-server-source-dir
  (expand-file-name "server" (file-name-directory (find-library-name "irony")))
  "Points to the irony-server source directory.

This should point to the directory that contains the top-most
CMakeLists.txt used to build the server."
  :type 'directory
  :group 'irony)

(defcustom irony-server-build-dir (concat irony-user-dir "build/")
  "Build directory for irony-server."
  :type 'directory
  :group 'irony)

(defcustom irony-server-install-prefix irony-user-dir
  "Installation prefix used to install irony-server.

The irony-server executable is expected to be in
`irony-server-install-prefix'/bin/."
  :type 'directory
  :group 'irony)

(defcustom irony-check-compile-functions
  '(irony--process-initial-check-compile)
  "Abnormal hook run when new check-compile results are available.

Takes as an argument the number of fatal errors (usually 0 or 1),
the number of errors and the number of warnings.

Example function:

  (defun my-irony-check-compile-function (nfatals nerrors nwarnings)
    (message \"%d error(s) and %d warning(s)\" (+ nfatals nerrors)\
 nwarnings))

  (add-hook 'irony-check-compile-functions\
 'my-irony-check-compile-function)"
  :type 'hook
  :options '(irony--process-initial-check-compile)
  :group 'irony)

(defcustom irony-source-file-extensions '("c"   "cc"
                                          "C"   "CC"
                                          "cpp" "cxx" "c++"
                                          "m"   "mm")
  "Known file extensions used for source code in C/C++/Obj-C.

Header files extensions should NOT take part of this list."
  :type '(choice (repeat string))
  :group 'irony)


;;
;; Public/API variables
;;
;; Non-customizable variables provided by Irony that can be useful to other
;; packages.
;;
;; Note that they shouldn't be modified directly by external packages, just
;; read.
;;

(defvar irony-header-search-directories nil
  "Header search directories list for the current buffer.

Contains the absolute paths to the directories.")

(defvar-local irony-clang-working-directory nil
  "The working directory to pass to libclang, if any.")


;;
;; Internal variables
;;
;; The prefix `irony--' is used when something can completely change (or
;; disappear) from one release to the other.
;;
;; -- https://lists.gnu.org/archive/html/emacs-devel/2013-06/msg01129.html

(defvar-local irony--clang-options nil
  "Compile options for the current file.

The compile options used by the compiler to build the current
buffer file.")

;; TODO: Diagnose the missing stddef.h and append the directory
;; https://github.com/Sarcasm/irony-mode/issues/28
(defvar-local irony--extra-clang-options nil)

(defconst irony--eot "\n;;EOT\n"
  "String sent by the server to signal the end of a response.")

(defconst irony-server-eot "\nEOT\n"
  "The string to send to the server to finish a transmission.")

(defvar irony-install-server-initiating-buffer)

(defvar-local irony-server-executable-path nil
  "Path to the irony-server executable to use for the current buffer.

Set to nil if not found.")

(defvar-local irony--initial-compile-check-status nil
  "Non-nil when an initial compile check as already been requested.

Possible values are:
- nil
- 'requested, when the compile check for the current buffer has
  been requested.
- 'done, when the compile check has been received and processed")


;;
;; Mode
;;

(defvar irony-mode-map (make-sparse-keymap)
  "Keymap used in `irony-mode' buffers.")

;;;###autoload
(define-minor-mode irony-mode
  "Minor mode for C, C++ and Objective-C, powered by libclang."
  nil
  irony-lighter
  irony-mode-map
  :group 'irony
  (if irony-mode
      (irony-mode-enter)
    (irony-mode-exit)))

(defun irony-mode-enter ()
  (when (not (memq major-mode irony-supported-major-modes))
    ;; warn the user about modes such as php-mode who inherits c-mode
    (display-warning 'irony "Irony mode is aimed to work with a\
 major mode present in `irony-supported-major-modes'."))
  ;;c-mode-hook and c++-mode-hook appears to run twice, avoid unecessary call
  ;;to `irony-locate-server-executable' if it has already be done once.
  (unless irony-server-executable-path
    (irony-locate-server-executable))
  (unless irony--clang-options
    (irony-cdb-load-compile-options))
  (when irony-server-executable-path
    (irony--initial-check-compile)))

(defun irony-mode-exit ())


;;
;; Utility functions & macros
;;

(defmacro irony--aif (test if-expr &rest else-body)
  (declare (indent 2))
  `(let ((it ,test))
     (if it
         ,if-expr
       (progn ,@else-body))))

(defmacro irony--awhen (test &rest body)
  (declare (indent 1))
  `(let ((it ,test))
     (when it
       (progn ,@body))))

(defmacro irony-without-narrowing (&rest body)
  "Remove the effect of narrowing for the current buffer.

Note: If `save-excursion' is needed for BODY, it should be used
before calling this macro."
  (declare (indent 0) (debug t))
  `(save-restriction
     (widen)
     (progn ,@body)))

(defun irony-version (&optional show-version)
  "Return the version number of the file irony.el.

If called interactively display the version in the echo area."
  (interactive "P")
  ;; Shamelessly stolen from `company-mode'.
  (with-temp-buffer
    (insert-file-contents (find-library-name "irony"))
    (let ((v (lm-version)))
      (when show-version
        (message "irony version: %s" v))
      v)))

(defun irony-buffer-size-in-bytes ()
  "Return the buffer size, in bytes."
  (1- (position-bytes (point-max))))

(defun irony--read-char-choice (prompt chars)
  "Wrapper around `read-char-choice', available since Emacs 24."
  (setq prompt (concat prompt " [" chars "]: "))
  (if (fboundp 'read-char-choice)
      (read-char-choice prompt chars)
    (setq prompt (propertize prompt 'face 'minibuffer-prompt))
    (let ((cursor-in-echo-area t)
          k)
      (while (not (member k chars))
        (setq k (read-char-exclusive prompt)))
      k)))

(defun irony--shorten-path (path)
  "Make PATH as short as possible.

The given path can be considered understandable by human but not
necessary a valid path string to use in code. Its only purpose is
to be displayed to the user."
  (let ((relative (file-relative-name path))
        (abbreviated (abbreviate-file-name path)))
    (if (< (string-width relative) (string-width abbreviated))
        relative
      abbreviated)))

(defun irony-split-command-line-1 (quoted-str)
  "Remove the escaped quotes and backlash from a QUOTED-STR.

Return a list of the final characters in the reverse order, only
to be consumed by `irony-split-command-line'."
  (let ((len (length quoted-str))
        (i 0)
        ch next-ch
        result)
    (while (< i len)
      (setq ch (aref quoted-str i))
      (when (eq ch ?\\)
        (let ((next-ch (and (< (1+ i) len)
                            (aref quoted-str (1+ i)))))
          (when (member next-ch '(?\\ ?\"))
            (setq ch next-ch)
            (incf i))))
      (push ch result)
      (incf i))
    result))

(defun irony-split-command-line (cmd-line)
  "Split CMD-LINE into a list of arguments.

Takes care of double quotes as well as backslash.

Sadly I had to write this because `split-string-and-unquote'
breaks with escaped quotes in compile_commands.json, such as in:

    /usr/bin/c++ -DLLVM_VERSION_INFO=\\\\\\\"3.2svn\\\\\\\" <args>"
  ;; everytime I write a function like this one, it makes me feel bad
  (let* ((len (length cmd-line))
         (spaces (string-to-list " \f\t\n\r\v"))
         (first-not-spaces-re (concat "[^" spaces "]"))
         (i 0)
         ch
         args cur-arg)
    (while (< i len)
      (setq ch (aref cmd-line i))
      (cond
       ((member ch spaces)              ;spaces
        (when cur-arg
          (setq args (cons (apply 'string (nreverse cur-arg)) args)
                cur-arg nil))
        ;; move to the next char
        (setq i (or (string-match-p first-not-spaces-re cmd-line i)
                    len)))
       ((eq ch ?\")                     ;quoted string
        (let ((endq (string-match-p "[^\\]\"" cmd-line i)))
          (unless endq
            (error "Irony: ill formed command line"))
          (let ((quoted-str (substring cmd-line (1+ i) (1+ endq))))
            (setq cur-arg (append (irony-split-command-line-1 quoted-str)
                                  cur-arg)
                  i (+ endq 2)))))
       (t                             ;a valid char
        ;; if it's an escape of: a backslash, a quote or a space push
        ;; only the following char.
        (when (eq ch ?\\)
          (let ((next-ch (and (< (1+ i) len)
                              (aref cmd-line (1+ i)))))
            (when (or (member next-ch '(?\\ ?\"))
                      (member next-ch spaces))
              (setq ch next-ch)
              (incf i))))
        (push ch cur-arg)
        (incf i))))
    (when cur-arg
      (setq args (cons (apply 'string (nreverse cur-arg)) args)))
    (nreverse args)))


;;
;; Compile options handling
;;

(defun irony-update-command-line-options (cmd-line-options
                                          &optional
                                          working-directory)
  "Setup the command line options to pass down to libclang."
  (setq irony--clang-options cmd-line-options
        irony-clang-working-directory working-directory)
  (run-hooks irony-clang-options-updated-hook))

(defun irony--libclang-lang-compile-options ()
  (irony--awhen (cdr-safe (assq major-mode irony-clang-lang-options-alist))
    (list "-x" it)))

(defun irony--libclang-compile-options ()
  "The compile options to send to libclang."
  ;; TODO: if current buffer has no associated file (will be sent as '-') but is
  ;; in an existing directory, we will want to add -I (directory-file-name
  ;; buffer-file-name) to find the relative headers
  (append
   (irony--libclang-lang-compile-options)
   (irony--awhen irony-clang-working-directory
     (unless (irony--extract-working-directory-option irony--clang-options)
       (list "-working-directory" it)))
   irony-additional-clang-options
   irony--extra-clang-options
   irony--clang-options))

(defun irony--extract-working-directory-option (flags)
  "Look in FLAGS for the '-working-directory' option, if any."
  (catch 'found
    (while flags
      (let ((flag (car flags)))
        (cond
         ((string= "-working-directory" flag)
          (throw 'found (cadr flags)))
         ((string-prefix-p "-working-directory=" flag)
          (throw 'found (substring flag (length "-working-directory="))))
         (t
          (setq flags (cdr flags))))))))


;;
;; Irony-Server setup
;;

(defun irony-install-server-finish-function (buffer msg)
  (if (string= "finished\n" msg)
      (progn
        (message "irony-server installed successfully!")
        (with-current-buffer buffer
          (if (buffer-live-p irony-install-server-initiating-buffer)
              (with-current-buffer irony-install-server-initiating-buffer
                (if irony-mode
                    (irony-locate-server-executable))))))
    ;; failed to build/install
    ;; TODO: detect common issues:
    ;; - cmake not installed, or installed in a specific place
    ;;   could be detected before compilation and the user can be prompted to
    ;;   customize `irony-cmake-executable'
    ;; - libclang not found
    ;; - ...
    (message "Failed to build irony-server, you are on your own buddy!")))

(defun irony-install-server ()
  "Install or reinstall the Irony server.

The installation requires CMake and the libclang developpement package."
  (interactive)
  (let ((cur-buf (current-buffer))
        (default-directory irony-server-build-dir)
        (cmd (format
              (concat "%s -DCMAKE_INSTALL_PREFIX=%s %s && %s --build . "
                      "--use-stderr --config Release --target install")
              (shell-quote-argument irony-cmake-executable)
              (shell-quote-argument (expand-file-name
                                     irony-server-install-prefix))
              (shell-quote-argument irony-server-source-dir)
              (shell-quote-argument irony-cmake-executable))))
    (make-directory irony-server-build-dir t)
    (with-current-buffer (compilation-start cmd nil #'(lambda (maj-mode)
                                                        "*irony-server build*"))
      (setq-local irony-install-server-initiating-buffer cur-buf)
      (setq-local compilation-finish-functions
                  '(irony-install-server-finish-function)))))

(defun irony-locate-server-executable ()
  "Check if an irony-server exists for the current buffer."
  (let ((exe (expand-file-name "bin/irony-server" irony-server-install-prefix)))
    (condition-case err
        (let ((irony-server-version (car (process-lines exe "--version"))))
          (if (and (string-match "^irony-server version " irony-server-version)
                   (version= (irony-version)
                             (substring irony-server-version
                                        (length "irony-server version "))))
              ;; irony-server is working and up-to-date!
              (setq irony-server-executable-path exe)
            (message "irony versions mismatch, forgot to call\
 'M-x irony-install-server'?") ))
      (error
       (if (file-executable-p exe)
           ;; failed to execute due to a runtime problem, i.e: libclang.so isn't
           ;; in the ld paths
           (message "error: irony-server is broken, good luck buddy! %s"
                    (error-message-string err))
         ;; irony-server doesn't exists, first time irony-mode is used? inform
         ;; the user about how to build the executable
         (message "Please install irony-server: M-x irony-install-server"))))))

(defun irony--initial-check-compile ()
  "Check that the current buffer compiles, hinting the user if not.

Ideally this is done only once, when the buffer is first
opened (or irony-mode first started), just to inform the user if
he forgot to provide the flags for the current buffer."
  (unless irony--initial-compile-check-status
    (setq irony--initial-compile-check-status 'requested)
    (irony-request-check-compile)))

(defun irony--process-initial-check-compile (nfatals nerrors nwarnings)
  "Display a one-time hint to the user to configure the compile options.

See `irony-check-compile-functions'."
  (when (and (eq irony--initial-compile-check-status 'requested)
             (not (zerop (+ nfatals nerrors nwarnings))))
    (setq irony--initial-compile-check-status 'done)
    (let ((help-msg (substitute-command-keys
                     "Type `\\[irony-cdb-menu]' to configure project"))
          stats-strings)
      (unless (zerop nwarnings)
        (push (concat (number-to-string nwarnings)
                      " warning"
                      (unless (eq nwarnings 1) ;plural
                        "s"))
              stats-strings))
      (setq nerrors (+ nfatals nerrors))
      (unless (zerop nerrors)
        (push (concat (number-to-string nerrors)
                      " error"
                      (unless (eq nerrors 1) ;plural
                        "s"))
              stats-strings))
      (message "[%s] %s" (mapconcat 'identity stats-strings " | ")
               help-msg))))


;;
;; irony-server process management.
;;

(defun irony--server-command ()
  "Shell command used to start the irony-server process."
  (format "%s -i 2>> %s/irony.$$.log"
          (shell-quote-argument irony-server-executable-path)
          temporary-file-directory))

(defvar irony--server-process nil)

(defun irony--get-server-process ()
  (if (and irony--server-process
           (process-live-p irony--server-process))
      irony--server-process
    (let ((process-connection-type nil)
          process)
      (setq process (start-process-shell-command
                     "Irony"                   ;process name
                     "*Irony*"                 ;buffer
                     (irony--server-command))) ;command
      (set-process-query-on-exit-flag process nil)
      (set-process-sentinel process 'irony--server-process-sentinel)
      (set-process-filter process 'irony--server-process-filter)
      (setq irony--server-process process))))

(defun irony--server-process-sentinel (process event)
  (unless (process-live-p process)
    (setq irony--server-process nil)
    (message "irony process stopped!")))

(defun irony--process-server-response (process response)
  (let ((sexp (read response))
        (callback (irony--server-process-pop-callback process)))
    (apply (car callback) sexp (cdr callback))))

(defun irony--server-process-filter (process output)
  "Handle output that come from an irony-server process."
  (let ((pbuf (process-buffer process))
        responses)
    ;; append output to process buffer
    (when (buffer-live-p pbuf)
      (with-current-buffer pbuf
        (save-excursion
          (goto-char (process-mark process))
          (insert output)
          (set-marker (process-mark process) (point))
          ;; check if the message is complete based on `irony--eot'
          (goto-char (point-min))
          (while (search-forward irony--eot nil t)
            (let ((response (buffer-substring-no-properties (point-min)
                                                            (point))))
              (delete-region (point-min) (point))
              (setq responses (cons response responses))
              (goto-char (process-mark process)))))))
    ;; Handle all responses.
    (mapc #'(lambda (r)
              (irony--process-server-response process r))
          (nreverse responses))))

(defun irony--server-process-push-callback (p cb)
  (let ((callbacks (process-get p 'irony-callback-stack)))
    (if callbacks
        (nconc callbacks (list cb))
      (process-put p 'irony-callback-stack (list cb)))))

(defun irony--server-process-pop-callback (p)
  (let ((callbacks (process-get p 'irony-callback-stack)))
    (process-put p 'irony-callback-stack (cdr callbacks))
    (car callbacks)))

(defun irony--server-process-callback-count (p)
  (length (process-get p 'irony-callback-stack)))


;;
;; Server commands
;;

(defun irony--get-buffer-path-for-server ()
  "Get the path of the current buffer to send to irony-server.

If no such file exists on the filesystem the special file '-' is
  returned instead."
  (if (and buffer-file-name (file-exists-p buffer-file-name))
      buffer-file-name
    "-"))

(defun irony--send-file-request (request callback &rest args)
  "Send a request that acts on the current buffer to irony-server.

This concerns mainly irony-server commands that do some work on a
translation unit for libclang, the unsaved buffer data are taken
care of."
  (let ((process (irony--get-server-process))
        (argv (append (list request
                            "--num-unsaved=1"
                            (irony--get-buffer-path-for-server))
                      args))
        (compile-options (irony--libclang-compile-options)))
    (irony--server-process-push-callback process callback)
    ;; skip narrowing to compute buffer size and content
    (irony-without-narrowing
      (process-send-string process
                           (format "%s\n%s\n%s\n%d\n"
                                   (combine-and-quote-strings argv)
                                   (combine-and-quote-strings compile-options)
                                   buffer-file-name
                                   (irony-buffer-size-in-bytes)))
      (process-send-region process (point-min) (point-max))
      ;; always make sure to finis with a newline (required by irony-server to
      ;; play nice with line buffering even when the file doesn't end with a
      ;; newline)
      (process-send-string process "\n"))))

(defun irony-request-check-compile ()
  (irony--send-file-request "check-compile"
                            (list 'irony-check-compile-handler)))

(defun irony-check-compile-handler (errors)
  (run-hook-with-args 'irony-check-compile-functions
                      (or (plist-get errors :fatals) 0)
                      (or (plist-get errors :errors) 0)
                      (or (plist-get errors :warnings) 0)))


;;
;; TODO
;;

(defun irony--request-completion (&rest args))

(defun irony-current-directory ()
  default-directory)

(defun irony-user-search-paths ()
  nil)

(provide 'irony)

(require 'irony-cdb)

;; Local Variables:
;; byte-compile-warnings: (not cl-functions)
;; End:

;;; irony.el ends here
