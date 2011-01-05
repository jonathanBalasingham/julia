(define ops-by-prec
  '#((= := += -= *= /= //= .//= .*= ./= |\\=| |.\\=| ^= .^= %= |\|=| &= $= => <<= >>= >>>=)
     (?)
     (|\|\||)
     (&&)
     ; note: there are some strange-looking things in here because
     ; the way the lexer works, every prefix of an operator must also
     ; be an operator.
     (-> <- -- -->)
     (> < >= <= == != |.>| |.<| |.>=| |.<=| |.==| |.!=| |.=| |.!| |<:| |>:|)
     (: ..)
     (+ - |\|| $)
     (<< >> >>>)
     (* / // .// |./| % & |.*| |\\| |.\\|)
     (^ |.^|)
     (|::|)
     (|.|)))

(define-macro (prec-ops n) `(aref ops-by-prec ,n))

(define normal-ops (vector.map identity ops-by-prec))
(define no-pipe-ops (vector.map identity ops-by-prec))
(vector-set! no-pipe-ops 7 '(+ - $))
(define range-colon-enabled #t)
; in space-sensitive mode "x -y" is 2 expressions, not a subtraction
(define space-sensitive #f)
; treat 'end' like a normal symbol instead of a reserved word
(define end-symbol #f)

(define-macro (with-normal-ops . body)
  `(with-bindings ((ops-by-prec normal-ops)
		   (range-colon-enabled #t)
		   (space-sensitive #f))
		  ,@body))

(define-macro (without-bitor . body)
  `(with-bindings ((ops-by-prec no-pipe-ops))
		  ,@body))

(define-macro (without-range-colon . body)
  `(with-bindings ((range-colon-enabled #f))
		  ,@body))

(define-macro (with-space-sensitive . body)
  `(with-bindings ((space-sensitive #t))
		  ,@body))

(define-macro (with-end-symbol . body)
  `(with-bindings ((end-symbol #t))
		  ,@body))

(define unary-ops '(+ - ! ~ $ |<:| |>:|))

; operators that are both unary and binary
(define unary-and-binary-ops '(+ - $))

; operators that are special forms, not function names
(define syntactic-operators
  '(= := += -= *= /= //= .//= .*= ./= |\\=| |.\\=| ^= .^= %= |\|=| &= $= =>
      <<= >>= -> --> |\|\|| && : |::| |.|))
(define syntactic-unary-operators '($))

(define reserved-words '(begin while if for try return break continue
			 function macro quote let local global const
			 type typealias struct bitstype
			 module import export))

(define (syntactic-op? op) (memq op syntactic-operators))
(define (syntactic-unary-op? op) (memq op syntactic-unary-operators))

(define trans-op (string->symbol ".'"))
(define ctrans-op (string->symbol "'"))
(define vararg-op (string->symbol "..."))

(define operators (list* '~ '! ctrans-op trans-op vararg-op
			 (delete-duplicates
			  (apply append (vector->list ops-by-prec)))))

(define op-chars
  (list->string
   (delete-duplicates
    (apply append
	   (map string->list (map symbol->string operators))))))

; --- lexer ---

(define special-char?
  (let ((chrs (string->list "()[]{},;\"`@")))
    (lambda (c) (memv c chrs))))
(define (newline? c) (eqv? c #\newline))
(define (identifier-char? c) (or (and (char>=? c #\A)
				      (char<=? c #\Z))
				 (and (char>=? c #\a)
				      (char<=? c #\z))
				 (and (char>=? c #\0)
				      (char<=? c #\9))
				 (char>=? c #\uA1)
				 (eqv? c #\_)))
(define (opchar? c) (string.find op-chars c))
(define (operator? c) (memq c operators))

(define (skip-to-eol port)
  (let ((c (peek-char port)))
    (cond ((eof-object? c)    c)
	  ((eqv? c #\newline) c)
	  (else               (read-char port)
			      (skip-to-eol port)))))

(define (read-operator port c)
  (read-char port)
  (if (or (eof-object? (peek-char port)) (not (opchar? (peek-char port))))
      (symbol (string c)) ; 1-char operator
      (let loop ((str (string c))
		 (c   (peek-char port)))
	(if (and (not (eof-object? c)) (opchar? c))
	    (let ((newop (string str c)))
	      (if (operator? (string->symbol newop))
		  (begin (read-char port)
			 (loop newop (peek-char port)))
		  (string->symbol str)))
	    (string->symbol str)))))

(define (accum-tok-eager c pred port)
  (let loop ((str '())
	     (c c))
    (if (and (not (eof-object? c)) (pred c))
	(begin (read-char port)
	       (loop (cons c str) (peek-char port)))
	(list->string (reverse str)))))

(define (read-number port . leadingdot)
  (let ((str  (open-output-string))
	(pred char-numeric?))
    (define (allow ch)
      (let ((c (peek-char port)))
	(and (eqv? c ch)
	     (begin (write-char (read-char port) str) #t))))
    (define (disallow ch)
      (if (eqv? (peek-char port) ch)
	  (error (string "invalid numeric constant "
			 (get-output-string str) ch))))
    (define (read-digs)
      (let ((d (accum-tok-eager (peek-char port) pred port)))
	(and (not (equal? d ""))
	     (not (eof-object? d))
	     (display d str)
	     #t)))
    (if (pair? leadingdot)
	(write-char #\. str)
	(if (eqv? (peek-char port) #\0)
	    (begin (write-char (read-char port) str)
		   (if (allow #\x)
		       (set! pred (lambda (c)
				    (or (char-numeric? c)
					(and (>= c #\a) (<= c #\f))
					(and (>= c #\A) (<= c #\F)))))))
	    (allow #\.)))
    (read-digs)
    (allow #\.)
    (read-digs)
    (disallow #\.)
    (if (or (allow #\e) (allow #\E))
	(begin (or (allow #\+) (allow #\-))
	       (read-digs)
	       (disallow #\.)))
    (let* ((s (get-output-string str))
	   (n (string->number s)))
      (if n n
	  (error (string "invalid numeric constant " s))))))

(define (skip-ws-and-comments port)
  (skip-ws port #t)
  (if (eqv? (peek-char port) #\#)
      (begin (skip-to-eol port)
	     (skip-ws-and-comments port)))
  #t)

(define (next-token port s)
  (aset! s 2 (eq? (skip-ws port #f) #t))
  (let ((c (peek-char port)))
    (cond ((or (eof-object? c) (newline? c))  (read-char port))

	  ((char-numeric? c)    (read-number port))
	  
	  ((identifier-char? c) (accum-julia-symbol c port))

	  ((special-char? c)    (read-char port))

	  ((eqv? c #\#)         (skip-to-eol port) (next-token port s))
	  
	  ; . is difficult to handle; it could start a number or operator
	  ((and (eqv? c #\.)
		(let ((c (read-char port))
		      (nextc (peek-char port)))
		  (cond ((char-numeric? nextc)
			 (read-number port c))
			((opchar? nextc)
			 (string->symbol
			  (string-append (string c)
					 (symbol->string
					  (read-operator port nextc)))))
			(else '|.|)))))
	  
	  ((opchar? c)  (read-operator port c))

	  #;((eqv? c #\")
	   (with-exception-catcher
	    (lambda (e)
	      (error "invalid string literal"))
	    (lambda () (read port))))

	  (else (error (string "invalid character " (read-char port)))))))

; --- parser ---

(define (make-token-stream s) (vector #f s #t #f))
(define-macro (ts:port s)       `(aref ,s 1))
(define-macro (ts:last-tok s)   `(aref ,s 0))
(define-macro (ts:set-tok! s t) `(aset! ,s 0 ,t))
(define-macro (ts:space? s)     `(aref ,s 2))
(define-macro (ts:pbtok s)      `(aref ,s 3))
(define (ts:put-back! s t)
  (if (ts:pbtok s)
      (error "too many pushed-back tokens (internal error)")
      (aset! s 3 t)))

(define (peek-token s)
  (or (ts:pbtok s)
      (ts:last-tok s)
      (begin (ts:set-tok! s (next-token (ts:port s) s))
	     (ts:last-tok s))))

(define (require-token s)
  (let ((t (or (ts:pbtok s) (ts:last-tok s) (next-token (ts:port s) s))))
    (if (eof-object? t)
	(error "incomplete: premature end of input")
	(if (newline? t)
	    (begin (take-token s)
		   (require-token s))
	    (begin (if (not (ts:pbtok s)) (ts:set-tok! s t))
		   t)))))

(define (take-token s)
  (or
   (begin0 (ts:pbtok s)
	   (aset! s 3 #f))
   (begin0 (ts:last-tok s)
	   (ts:set-tok! s #f))))

; parse left-to-right binary operator
; produces structures like (+ (+ (+ 2 3) 4) 5)
(define (parse-LtoR s down ops)
  (let loop ((ex (down s)))
    (let ((t (peek-token s)))
      (if (not (memq t ops))
	  ex
	  (begin (take-token s)
		 (if (syntactic-op? t)
		     (loop (list t ex (down s)))
		     (loop (list 'call t ex (down s)))))))))

; parse right-to-left binary operator
; produces structures like (= a (= b (= c d)))
(define (parse-RtoL s down ops)
  (let ((ex (down s)))
    (let ((t (peek-token s)))
      (if (not (memq t ops))
	  ex
	  (begin (take-token s)
		 (if (syntactic-op? t)
		     (list t ex (parse-RtoL s down ops))
		     (list 'call t ex (parse-RtoL s down ops))))))))

(define (parse-cond s)
  (let ((ex (parse-or s)))
    (if (not (eq? (peek-token s) '?))
	ex
	(begin (take-token s)
	       (let ((then (without-range-colon (parse-eq* s))))
		 (if (not (eq? (take-token s) ':))
		     (error "colon expected in ? expression")
		     (list 'if ex then (parse-cond s))))))))

(define (invalid-initial-token? tok)
  (or (eof-object? tok)
      (memv tok '(#\) #\] #\} else elseif catch))))

; parse a@b@c@... as (@ a b c ...) for some operator @
; op: the operator to look for
; head: the expression head to yield in the result, e.g. "a;b" => (block a b)
; closers: a list of tokens that will stop the process
;          however, this doesn't consume the closing token, just looks at it
; allow-empty: if true will ignore runs of the operator, like a@@@@b
; ow, my eyes!!
(define (parse-Nary s down op head closers allow-empty)
  (if (invalid-initial-token? (require-token s))
      (error (string "unexpected token " (peek-token s))))
  (if (memv (require-token s) closers)
      (list head)  ; empty block
      (let loop ((ex
                  ; in allow-empty mode skip leading runs of operator
		  (if (and allow-empty (eqv? (require-token s) op))
		      '()
		      (list (down s))))
		 (first? #t))
	(let ((t (peek-token s)))
	  (if (not (eqv? t op))
	      (if (or (null? ex) (pair? (cdr ex)) (not first?))
	          ; () => (head)
	          ; (ex2 ex1) => (head ex1 ex2)
	          ; (ex1) ** if operator appeared => (head ex1) (handles "x;")
		  (cons head (reverse ex))
	          ; (ex1) => ex1
		  (car ex))
	      (begin (take-token s)
		     ; allow input to end with the operator, as in a;b;
		     (if (or (eof-object? (peek-token s))
			     (memv (peek-token s) closers)
			     (and allow-empty
				  (eqv? (peek-token s) op)))
			 (loop ex #f)
			 (loop (cons (down s) ex) #f))))))))

; colon is strange; 3 arguments with 2 colons yields one call:
; 1:2   => (: 1 2)
; 1:2:3 => (: 1 2 3)
; 1:    => (: 1 :)
; 1:2:  => (: 1 2 :)
;; not enabled:
;;; :2    => (: 2)
;;; :1:2  => (: (: 1 2))
;;; :1:   => (: (: 1 :))
; a simple state machine is up to the task.
; we will leave : expressions as a syntax form, not a call to ':',
; so they can be processed by syntax passes.
(define (parse-range s)
  (if (not range-colon-enabled)
      (return (parse-expr s)))
  (let loop ((ex (parse-expr s))
	     (first? #t))
    (let ((t (peek-token s)))
      (if (not (eq? t ':))
	  ex
	  (begin (take-token s)
		 (let ((argument
			(if (closing-token? (peek-token s))
			    ':  ; missing last argument
			    (parse-expr s))))
		   (if first?
		       (loop (list t ex argument) #f)
		       (loop (append ex (list argument)) #t))))))))

; the principal non-terminals follow, in increasing precedence order

(define (parse-block s) (parse-Nary s parse-block-stmts #\newline 'block
				    '(end else elseif catch) #t))
(define (parse-block-stmts s) (parse-Nary s parse-eq #\; 'block
					  '(end else elseif catch #\newline)
					  #t))
(define (parse-stmts s) (parse-Nary s parse-eq    #\; 'block '(#\newline) #t))

(define (parse-eq s)    (parse-RtoL s parse-comma (prec-ops 0)))
; parse-eq* is used where commas are special, for example in an argument list
(define (parse-eq* s)   (parse-RtoL s parse-cond  (prec-ops 0)))
; parse-comma is needed for commas outside parens, for example a = b,c
(define (parse-comma s) (parse-Nary s parse-cond  #\, 'tuple '( #\) ) #f))
(define (parse-or s)    (parse-LtoR s parse-and   (prec-ops 2)))
(define (parse-and s)   (parse-LtoR s parse-arrow (prec-ops 3)))
(define (parse-arrow s) (parse-RtoL s parse-ineq  (prec-ops 4)))
(define (parse-ineq s)  (parse-comparison s (prec-ops 5)))
		      ; (parse-LtoR s parse-range (prec-ops 5)))
;(define (parse-range s) (parse-LtoR s parse-expr  (prec-ops 6)))
;(define (parse-expr s)  (parse-LtoR/chains s parse-shift (prec-ops 8) '(+)))
;(define (parse-term s)  (parse-LtoR/chains s parse-unary (prec-ops 9) '(*)))

; parse left to right, combining chains of certain operators into 1 call
; e.g. a+b+c => (call + a b c)
(define (parse-expr s)
  (let ((ops (prec-ops 7)))
    (let loop ((ex       (parse-shift s))
	       (chain-op #f))
      (let* ((t   (peek-token s))
	     (spc (ts:space? s)))
	(if (not (memq t ops))
	    ex
	    (begin
	      (take-token s)
	      (cond ((and space-sensitive spc (memq t unary-and-binary-ops)
			  (or (peek-token s) #t) (not (ts:space? s)))
		     ; here we have "x -y"
		     (ts:put-back! s t)
		     ex)
		    ((eq? t chain-op)
		     (loop (append ex (list (parse-shift s)))
			   chain-op))
		    (else
		     (loop (list 'call t ex (parse-shift s))
			   (and (eq? t '+) t))))))))))

(define (parse-shift s) (parse-LtoR s parse-term (prec-ops 8)))

; given an expression and the next token, is there a juxtaposition
; operator between them?
(define (juxtapose? expr t)
  (and (not (operator? t))
       (not (operator? expr))
       (not (memq t reserved-words))
       (not (closing-token? t))
       (not (newline? t))
       (or (number? expr)
	   (not (memv t '(#\( #\[ #\{))))))

(define (parse-term s)
  (let ((ops (prec-ops 9)))
    (let loop ((ex       (parse-unary s))
	       (chain-op #f))
      (let ((t (peek-token s)))
	(cond ((and (symbol? ex) (eqv? t #\") (not (operator? ex)))
	       ;; custom prefixed string literals, x"s" does @x_str "s"
	       (let ((str (parse-atom s))
		     (macname (symbol (string ex '_str))))
		 (if (string? str)
		     `(macrocall ,macname ,str)
		     `(macrocall ,macname ,(caddr str)))))
	      ((and (juxtapose? ex t)
		    (not (ts:space? s)))
	       (if (eq? chain-op '*)
		   (loop (append ex (list (parse-unary s)))
			 chain-op)
		   (loop (list 'call '* ex (parse-unary s))
			 '*)))
	      ((not (memq t ops))
	       ex)
	      ((eq? t chain-op)
	       (begin (take-token s)
		      (loop (append ex (list (parse-unary s)))
			    chain-op)))
	      (else
	       (begin (take-token s)
		      (loop (list 'call t ex (parse-unary s))
			    (and (eq? t '*) t)))))))))

(define (parse-comparison s ops)
  (let loop ((ex (parse-range s))
	     (first #t))
    (let ((t (peek-token s)))
      (if (not (memq t ops))
	  ex
	  (begin (take-token s)
		 (if first
		     (loop (list 'comparison ex t (parse-range s)) #f)
		     (loop (append ex (list t (parse-range s))) #f)))))))

; flag an error for tokens that cannot begin an expression
(define (closing-token? tok)
  (or (eof-object? tok)
      (and (eq? tok 'end) (not end-symbol))
      (memv tok '(#\, #\) #\] #\} #\; else elseif catch))))

(define (parse-unary s)
  (let ((t (require-token s)))
    (if (closing-token? t)
	(error (string "unexpected token " t)))
    (cond ((memq t unary-ops)
	   (let ((op (take-token s))
		 (next (peek-token s)))
	     (if (closing-token? next)
		 op  ; return operator by itself, as in (+)
		 (if (syntactic-unary-op? op)
		     (list op (parse-unary s))
		     (list 'call op (parse-unary s))))))
	  ((eq? t '|::|)
	   ; allow ::T, omitting argument name
	   (take-token s)
	   `(|::| ,(gensym) ,(parse-call s)))
	  (else
	   (parse-factor s)))))

; handle ^, .^, and postfix ...
(define (parse-factor-h s down ops)
  (let ((ex (down s)))
    (let ((t (peek-token s)))
      (cond ((eq? t '...)
	     (take-token s)
	     (list '... ex))
	    ((not (memq t ops))
	     ex)
	    (else
	     (list 'call
		   (take-token s) ex (parse-factor-h s parse-unary ops)))))))

; -2^3 is parsed as -(2^3), so call parse-decl for the first argument,
; and parse-unary from then on (to handle 2^-3)
(define (parse-factor s)
  (parse-factor-h s parse-decl (prec-ops 10)))

(define (parse-decl s) (parse-LtoR s parse-call (prec-ops 11)))

; parse function call, indexing, dot, and transpose expressions
; also handles looking for syntactic reserved words
(define (parse-call s)
  (let ((ex (parse-atom s)))
    (if (memq ex reserved-words)
	(parse-resword s ex)
	(let loop ((ex ex))
	  (let ((t (peek-token s)))
	    (if (and space-sensitive (ts:space? s)
		     (memv t '(#\( #\[ #\{ |'|)))
		ex
		(case t
		  ((#\( )   (take-token s)
		   (loop (list* 'call ex (parse-arglist s #\) ))))
		  ((#\[ )   (take-token s)
	           ; ref is syntax, so we can distinguish
	           ; a[i] = x  from
	           ; ref(a,i) = x
		   (loop (list* 'ref ex
				(with-end-symbol
				 (parse-arglist s #\] )))))
		  ((|.|)
		   (loop (list (take-token s) ex (parse-atom s))))
		  ((|.'|)   (take-token s)
		   (loop (list 'call 'transpose ex)))
		  ((|'|)    (take-token s)
		   (loop (list 'call 'ctranspose ex)))
		  ((#\{ )   (take-token s)
		   (loop (list* 'curly ex (parse-arglist s #\} ))))
		  (else ex))))))))

;(define (parse-dot s)  (parse-LtoR s parse-atom (prec-ops 12)))

; parse expressions or blocks introduced by syntactic reserved words
(define (parse-resword s word)
  (define (expect-end s)
    (let ((t (peek-token s)))
      (if (eq? t 'end)
	  (take-token s)
	  (error "incomplete: end expected"))))
  (with-normal-ops
  (case word
    ((begin)  (begin0 (parse-block s)
		      (expect-end s)))
    ((quote)  (begin0 (list 'quote (parse-block s))
		      (expect-end s)))
    ((while)  (begin0 (list 'while (parse-cond s) (parse-block s))
		      (expect-end s)))
    ((for)
     (let* ((ranges (parse-comma-separated-assignments s))
	    (body   (parse-block s)))
       (expect-end s)
       (let nest ((r ranges))
	 (if (null? r)
	     body
	     `(for ,(car r) ,(nest (cdr r)))))))
    ((if)
     (let* ((test (parse-cond s))
	    (then (if (memq (require-token s) '(else elseif))
		      '(block)
		      (parse-block s)))
	    (nxt  (require-token s)))
       (take-token s)
       (case nxt
	 ((end)     (list 'if test then))
	 ((elseif)  (list 'if test then (parse-resword s 'if)))
	 ((else)    (list 'if test then (parse-resword s 'begin)))
	 (else (error "improperly terminated if statement")))))
    ((let)
     (if (eqv? (peek-token s) #\newline)
	 (error "invalid let syntax"))
     (let* ((binds (parse-comma-separated-assignments s))
	    (ex    (parse-block s)))
       (expect-end s)
       `(let ,ex ,@binds)))
    ((local)  (list 'local  (cons 'vars
				  (parse-comma-separated-assignments s))))
    ((global) (list 'global (cons 'vars
				  (parse-comma-separated-assignments s))))
    ((function macro)
     (let ((sig (parse-call s)))
       (begin0 (list word sig (parse-block s))
	       (expect-end s))))
    ((struct)
     (let ((sig (parse-ineq s)))
       (begin0 (list word sig (parse-block s))
	       (expect-end s))))
    ((type)
     (list 'type (parse-ineq s)))
    ((bitstype)
     (list 'bitstype (parse-atom s) (parse-ineq s)))
    ((typealias)
     (let ((lhs (parse-call s)))
       (if (and (pair? lhs) (eq? (car lhs) 'call))
	   ;; typealias X (...) is tuple type alias, not call
	   (list 'typealias (cadr lhs) (cons 'tuple (cddr lhs)))
	   (list 'typealias lhs (parse-arrow s)))))
    ((try)
     (let* ((try-block (if (eq? (require-token s) 'catch)
			   '(block)
			   (parse-block s)))
	    (nxt       (require-token s)))
       (take-token s)
       (case nxt
	 ((end)   try-block)
	 ((catch) (let* ((var
			  (if (eqv? (peek-token s) #\newline)
			      (gensym)
			      (let ((v (parse-atom s)))
				(if (not (symbol? v))
				    (error "expected variable in catch"))
				v)))
			 (catch-block (parse-block s)))
		    (expect-end s)
		    (list 'try try-block var catch-block)))
	 (else (error "improperly terminated try block")))))
    ((return)          (list 'return (parse-eq s)))
    ((break continue)  (list word))
    (else (error "unhandled reserved word")))))

; parse comma-separated assignments, like "i=1:n,j=1:m,..."
(define (parse-comma-separated-assignments s)
  (let loop ((ranges '()))
    (let ((r (parse-eq* s)))
      (case (peek-token s)
	((#\,)  (take-token s) (loop (cons r ranges)))
	(else   (reverse! (cons r ranges)))))))

; handle function call argument list, or any comma-delimited list.
; . an extra comma at the end is allowed
; . expressions after a ; are enclosed in (parameters ...)
; . an expression followed by ... becomes (... x)
(define (parse-arglist s closer)
  (with-normal-ops (parse-arglist- s closer)))
(define (parse-arglist- s closer)
  (let loop ((lst '()))
    (let ((t (require-token s)))
      (if (equal? t closer)
	  (begin (take-token s)
		 (reverse lst))
	  (if (equal? t #\;)
	      (begin (take-token s)
		     (if (equal? (peek-token s) closer)
			 ; allow f(a, b; )
			 (begin (take-token s)
				(reverse lst))
			 (reverse (cons (cons 'parameters (loop '()))
					lst))))
	      (let* ((nxt (parse-eq* s))
		     (c (require-token s)))
		(cond ((eqv? c #\,)
		       (begin (take-token s) (loop (cons nxt lst))))
		      ((eqv? c #\;)          (loop (cons nxt lst)))
		      ((equal? c closer)     (loop (cons nxt lst)))
		      ; newline character isn't detectable here
		      #;((eqv? c #\newline)
		       (error "unexpected line break in argument list"))
		      (else
		       (error "missing separator in argument list")))))))))

(define (colons-to-ranges ranges)
  (map (lambda (r) (pattern-expand
		    (list
		     (pattern-lambda (: a b) `(call (top Range1) ,a ,b))
		     (pattern-lambda (: a b c) `(call (top Range) ,a ,b ,c)) )
		    r))
       ranges))

; parse [] concatenation expressions and {} cell expressions
(define (parse-cat s closer)
  (with-normal-ops
   (with-space-sensitive
    (parse-cat- s closer))))
(define (parse-cat- s closer)
  (define (fix head v) (cons head (reverse v)))
  (let loop ((vec '())
	     (outer '())
	     (first #t))
    (let ((update-outer (lambda (v)
			  (cond ((null? v)       outer)
				((null? (cdr v)) (cons (car v) outer))
				(else            (cons (fix 'hcat v) outer))))))
      (if (eqv? (require-token s) closer)
	  (begin (take-token s)
		 (if (pair? outer)
		     (fix 'vcat (update-outer vec))
		     (if (or (null? vec) (null? (cdr vec)))
			 (fix 'vcat vec)    ; [x]   => (vcat x)
			 (fix 'hcat vec)))) ; [x,y] => (hcat x y)
	  (let ((nv (cons (if first
			      (without-bitor (parse-eq* s))
			      (parse-eq* s))
			  vec)))
	    (case (if (eqv? (peek-token s) #\newline)
		      #\newline
		      (require-token s))
	      ((#\]) (if (eqv? closer #\])
			 (loop nv outer #f)
			 (error "unexpected ]")))
	      ((#\}) (if (eqv? closer #\})
			 (loop nv outer #f)
			 (error "unexpected }")))
	      ((|\||)
	       (begin (take-token s)
		      (let ((r (parse-comma-separated-assignments s)))
			(if (not (eqv? (require-token s) closer))
			    (error (string "expected " closer))
			    (take-token s))
			`(comprehension ,(car nv) ,@(colons-to-ranges r)))))
	      ((#\, #\; #\newline)
	       (begin (take-token s) (loop '() (update-outer nv) #f)))
	      (else
	       (begin (loop nv outer #f)))))))))

; for sequenced evaluation inside expressions: e.g. (a;b, c;d)
(define (parse-stmts-within-expr s)
  (parse-Nary s parse-eq* #\; 'block '(#\, #\) ) #t))

(define (parse-tuple s first)
  (let loop ((lst '())
	     (nxt first))
    (let ((t (require-token s)))
      (case t
	((#\))
	 (take-token s)
	 (cons 'tuple (reverse (cons nxt lst))))
	((#\,)
	 (take-token s)
	 (if (eqv? (require-token s) #\))
	     ;; allow ending with ,
	     (begin (take-token s)
		    (cons 'tuple (reverse (cons nxt lst))))
	     (loop (cons nxt lst) (parse-eq* s))))
	((#\;)
	 (error "unexpected semicolon in tuple"))
	#;((#\newline)
	 (error "unexpected line break in tuple"))
	(else
	 (error "missing separator in tuple"))))))

(define (not-eof-2 c)
  (if (eof-object? c)
      (error "incomplete: invalid ` syntax")
      c))

(define (parse-backquote s)
  (let ((b (open-output-string))
	(p (ts:port s)))
    (let loop ((c (read-char p)))
      (if (eqv? c #\`)
	  #t
	  (begin (if (eqv? c #\\)
		     (let ((nextch (read-char p)))
		       (if (eqv? nextch #\`)
			   (write-char nextch b)
			   (begin (write-char #\\ b)
				  (write-char (not-eof-2 nextch) b))))
		     (write-char (not-eof-2 c) b))
		 (loop (read-char p)))))
    (let ((str (io.tostring! b)))
      `(macrocall cmd ,str))))

(define (not-eof-3 c)
  (if (eof-object? c)
      (error "incomplete: invalid string syntax")
      c))

(define (parse-string-literal s)
  (let ((b (open-output-string))
	(p (ts:port s))
	(special #f))
    (let loop ((c (read-char p)))
      (if (eqv? c #\")
	  #t
	  (begin (if (eqv? c #\\)
		     (let ((nextch (read-char p)))
		       (if (eqv? nextch #\")
			   (write-char nextch b)
			   (begin (set! special #t)
                                  (write-char #\\ b)
				  (write-char (not-eof-3 nextch) b))))
		     (begin
		       (if (or (eqv? c #\$) (>= c 0x80))
			   (set! special #t))
		       (write-char (not-eof-3 c) b)))
		 (loop (read-char p)))))
    (let ((str (io.tostring! b)))
      (if special
	  `(macrocall str ,str)
	  str))))

(define (not-eof-1 c)
  (if (eof-object? c)
      (error "incomplete: invalid character literal")
      c))

; parse numbers, identifiers, parenthesized expressions, lists, vectors, etc.
(define (parse-atom s)
  (let ((t (require-token s)))
    (cond ((or (string? t) (number? t)) (take-token s))

	  ;; char literal
	  ((eq? t '|'|)
	   (take-token s)
	   (let ((firstch (read-char (ts:port s))))
	     (if (eqv? firstch #\')
	      (error "invalid character literal")
	      (if (and (not (eqv? firstch #\\))
		       (not (eof-object? firstch))
		       (eqv? (peek-char (ts:port s)) #\'))
	       ;; easy case: 1 character, no \
	       (begin (read-char (ts:port s)) firstch)
	       (let ((b (open-output-string)))
		 (let loop ((c firstch))
		   (if (eqv? c #\')
		       #t
		       (begin (write-char (not-eof-1 c) b)
			      (if (eqv? c #\\)
				  (write-char
				   (not-eof-1 (read-char (ts:port s))) b))
			      (loop (read-char (ts:port s))))))
		 (let ((str (read (open-input-string
				   (string #\" (io.tostring! b) #\")))))
		   (if (not (= (string-length str) 1))
		       (error "invalid character literal"))
		   (if (= (length str) 1)
		       ;; one byte, e.g. '\xff'. maybe not valid utf-8, but we
		       ;; want to use the raw value as a codepoint in this case.
		       (wchar (aref str 0))
		       (string.char str 0))))))))

	  ;; symbol/expression quote
	  ((eq? t ':)
	   (take-token s)
	   (if (closing-token? (peek-token s))
	       ':
	       (let ((ex (parse-atom s)))
		 (list 'quote ex))))

	  ;; identifier
	  ((symbol? t) (take-token s))

	  ;; parens or tuple
	  ((eqv? t #\( )
	   (take-token s)
	   (with-normal-ops
	   (if (eqv? (require-token s) #\) )
	       ;; empty tuple ()
	       (begin (take-token s) '(tuple))
	       ;; here we parse the first subexpression separately, so
	       ;; we can look for a comma to see if it's a tuple. this lets us
	       ;; distinguish (x) from (x,)
	       (let* ((ex (parse-eq* s))
		      (t (require-token s)))
		 (cond ((eqv? t #\) )
			(take-token s)
			;; value in parentheses (x)
			(if (and (pair? ex) (eq? (car ex) '...))
			    `(tuple ,ex)
			    ex))
		       ((eqv? t #\, )
			;; tuple (x,) (x,y) (x...) etc.
			(parse-tuple s ex))
		       ((eqv? t #\;)
			;; parenthesized block (a;b;c)
			(take-token s)
			(let* ((blk (parse-stmts-within-expr s))
			       (tok (require-token s)))
			  (if (eqv? tok #\,)
			      (error "unexpected comma in statement block"))
			  (if (not (eqv? tok #\)))
			      (error "missing separator in statement block"))
			  (take-token s)
			  `(block ,ex ,blk)))
		       #;((eqv? t #\newline)
			(error "unexpected line break in tuple"))
		       (else
			(error "missing separator in tuple")))))))

	  ;; cell expression
	  ((eqv? t #\{ )
	   (take-token s)
	   (if (eqv? (require-token s) #\})
	       (begin (take-token s) '(call (top cell_1d)))
	       (let ((vex (parse-cat s #\})))
		 (cond ((eq? (car vex) 'comprehension)
			(cons 'cell-comprehension (cdr vex)))
		       ((eq? (car vex) 'hcat)
			`(call (top cell_2d) 1 ,(length (cdr vex)) ,@(cdr vex)))
		       (else  ; (vcat ...)
			(if (and (pair? (cadr vex)) (eq? (caadr vex) 'hcat))
			    (let ((nr (length (cdr vex)))
				  (nc (length (cdadr vex))))
			      ;; make sure all rows are the same length
			      (if (not (every
					(lambda (x)
					  (and (pair? x)
					       (eq? (car x) 'hcat)
					       (length= (cdr x) nc)))
					(cddr vex)))
				  (error "inconsistent shape in cell expression"))
			      `(call (top cell_2d) ,nr ,nc
				     ,@(apply append
					      ;; transpose to storage order
					      (apply map list
						     (map cdr (cdr vex))))))
			    (if (any (lambda (x) (and (pair? x)
						      (eq? (car x) 'hcat)))
				     (cddr vex))
				(error "inconsistent shape in cell expression")
				`(call (top cell_1d) ,@(cdr vex)))))))))

	  ;; cat expression
	  ((eqv? t #\[ )
	   (take-token s)
	   (parse-cat s #\]))

	  ;; string literal
	  ((eqv? t #\")
	   (take-token s)
	   (parse-string-literal s))

	  ;; macro call
	  ((eqv? t #\@)
	   (take-token s)
	   (let ((head (parse-atom s)))
	     (if (not (symbol? head))
		 (error (string "invalid macro use @" head)))
	     `(macrocall ,head ,(parse-eq s))))

	  ;; command syntax
	  ((eqv? t #\`)
	   (take-token s)
	   (parse-backquote s))

	  (else (take-token s)))))

; --- main entry point ---

; can optionally specify which grammar production to parse.
; default is parse-stmts.
(define (julia-parse s . production)
  (cond ((string? s)
	 (apply julia-parse (make-token-stream (open-input-string s))
		production))
	((port? s)
	 (apply julia-parse (make-token-stream s) production))
	((eof-object? s)
	 s)
	(else
	 ; as a special case, allow early end of input if there is
	 ; nothing left but whitespace
	 (skip-ws-and-comments (ts:port s))
	 (if (eqv? (peek-token s) #\newline) (take-token s))
	 (let ((t (peek-token s)))
	   (if (eof-object? t)
	       t
	       ((if (null? production) parse-stmts (car production))
		s))))))

(define (check-end-of-input s)
  (skip-ws-and-comments (ts:port s))
  (if (eqv? (peek-token s) #\newline) (take-token s))
  (if (not (eof-object? (peek-token s)))
      (error (string "extra input after end of expression: "
		     (peek-token s)))))

(define (julia-parse-file filename stream)
  ; call f on a stream until the stream runs out of data
  (define (read-all-of f s)
    (with-exception-catcher
     (lambda (e)
       (if (and (pair? e) (eq? (car e) 'error))
	   (let ((msg (cadr e)))
	     (raise `(error ,(string msg " at " filename ":" 
				     (input-port-line (ts:port s))))))
	   (raise e)))
     (lambda ()
       (skip-ws-and-comments (ts:port s))
       (let loop ((lines '())
		  (linen (input-port-line (ts:port s)))
		  (curr  (f s)))
	 (if (eof-object? curr)
	     (reverse lines)
	     (begin
	       (skip-ws-and-comments (ts:port s))
	       (let ((nl (input-port-line (ts:port s))))
		 (loop (list* curr `(line ,linen) lines)
		       nl
		       (f s)))))))))
  (read-all-of julia-parse (make-token-stream stream)))
