#lang racket/base
(require racket/shared racket/match (for-syntax racket/base))
(define cur-section '())(define errs '())

(define-syntax defvar
  (syntax-rules ()
    [(_ name val)
     (define name val)
     #;
     (namespace-variable-value 'name #f
       (lambda () (namespace-set-variable-value! 'name val)))]))

(defvar building-flat-tests? #f)
(defvar in-drscheme?         #f)

;; used when quiet testing (through "quiet.rktl") to really show something
(defvar real-output-port #f)
(defvar real-error-port #f)

(define Section-prefix
  (namespace-variable-value 'Section-prefix #f (lambda () "")))

(define (Section . args)
  (let ([p (or real-output-port (current-output-port))])
    (fprintf p "~aSection~s\n" Section-prefix args)
    (flush-output p))
  (set! cur-section args)
  #t)

(define (record-error e)
  (set! errs (cons (list cur-section e) errs)))

(print-struct #t)

(define number-of-tests 0)
(define number-of-error-tests 0)
(define number-of-exn-tests 0)


(define test
  (let ()
    (define (test* expect fun args kws kvs)
      (define form
        `(,fun ,@args ,@(apply append (if kws (map list kws kvs) '()))))
      (set! number-of-tests (add1 number-of-tests))
      (printf "~s ==> " form)
      (flush-output)
      (let ([res (if (procedure? fun)
                   (if kws (keyword-apply fun kws kvs args) (apply fun args))
                   (car args))])
        (printf "~s\n" res)
        (let ([ok? (equal? expect res)])
          (unless ok?
            (record-error (list res expect form))
            (printf "  BUT EXPECTED ~s\n" expect))
          ok?)))
    (define (test/kw kws kvs expect fun . args) (test* expect fun args kws kvs))
    (define (test    expect fun         . args) (test* expect fun args #f #f))
    (make-keyword-procedure test/kw test)))

(define (nonneg-exact? x)
  (and (exact? x)
       (integer? x)
       (x . >= . 0)))

(define (pos-exact? x)
  (and (exact? x)
       (integer? x)
       (positive? x)))

(define exn-table
  (list (cons exn? (cons exn-message string?))
	(cons exn? (cons exn-continuation-marks continuation-mark-set?))
	(cons exn:fail:contract:variable? (cons exn:fail:contract:variable-id symbol?))
	(cons exn:fail:syntax? (cons exn:fail:syntax-exprs (lambda (x) (and (list? x) (andmap syntax? x)))))

	(cons exn:fail:read? (cons exn:fail:read-srclocs (lambda (x) (and (list? x) (andmap srcloc? x)))))))

(define exn:application:mismatch? exn:fail:contract?)
(define exn:application:type? exn:fail:contract?)
(define exn:application:arity? exn:fail:contract:arity?)

(define mz-test-syntax-errors-allowed? #t)

(define thunk-error-test
  (case-lambda
   [(th expr) (thunk-error-test th expr exn:application:type?)]
   [(th expr exn-type?)
    (set! expr (syntax->datum expr))
    (set! number-of-error-tests (add1 number-of-error-tests))
    (printf "~s  =e=> " expr)
    (flush-output)
    (call/ec (lambda (escape)
	       (let* ([old-esc-handler (error-escape-handler)]
		      [orig-err-port (current-error-port)]
		      [test-exn-handler
		       (lambda (e)
			 (when (and exn-type? (not (exn-type? e)))
			       (printf " WRONG EXN TYPE: ~s " e)
			       (record-error (list e 'exn-type expr)))
			 (when (and (exn:fail:syntax? e)
				    (not mz-test-syntax-errors-allowed?))
			       (printf " LATE SYNTAX EXN: ~s " e)
			       (record-error (list e 'exn-late expr)))

			 (for-each
			  (lambda (row)
			    (let ([pred? (car row)])
			      (when (pred? e)
				    (set! number-of-exn-tests
					  (add1 number-of-exn-tests))
				    (let ([sel (cadr row)]
					  [pred? (cddr row)])
				      (unless (pred? (sel e))
					      (printf " WRONG EXN ELEM ~s: ~s " sel e)
					      (record-error (list e (cons 'exn-elem sel) expr)))))))
			  exn-table)
                         
                         (printf "~s~n" (if (exn? e) (exn-message e) e))
                         #; ;g;
                         ((error-display-handler)
                          (if (exn? e)
                              (exn-message e)
                              (format "misc. exn: ~s" e))
                          e)

                         (escape #t))])
		 (dynamic-wind
		  (lambda ()
		    (current-error-port (current-output-port)))
		  (lambda ()
                    (call-with-continuation-prompt
                     (lambda ()
                       (call-with-exception-handler
                        test-exn-handler
                        (lambda ()
                          (let ([v (call-with-values th list)])
                            (write (cons 'values v))
                            (display " BUT EXPECTED ERROR")
                            (record-error (list v 'Error expr))
                            (newline)
                            #f))))))
		  (lambda ()
		    (current-error-port orig-err-port)
		    (error-escape-handler old-esc-handler))))))]))

(defvar error-test
  (case-lambda
    [(expr) (error-test expr exn:application:type?)]
    [(expr exn-type?) (thunk-error-test (lambda () (eval expr)) expr exn-type?)]))

(require (only-in racket [lambda err:mz:lambda])) ; so err/rt-test works with beginner.rktl
(define-syntax err/rt-test
  (lambda (stx)
    (syntax-case stx ()
      [(_ e exn?)
       (syntax
	(thunk-error-test (err:mz:lambda () e) (quote-syntax e) exn?))]
      [(_ e)
       (syntax
	(err/rt-test e exn:application:type?))])))

(define no-extra-if-tests? #f)

(define (syntax-test expr [rx #f])
  (error-test expr exn:fail:syntax?)
  (unless no-extra-if-tests?
    (error-test (datum->syntax expr `(if #f ,expr (void)) expr)
                (lambda (x)
                  (and (exn:fail:syntax? x)
                       (or (not rx)
                           (regexp-match? rx (exn-message x))))))))

(define arity-test
  (case-lambda
   [(f min max except)
    (letrec ([aok?
	      (lambda (a)
		(cond
		 [(integer? a) (= a min max)]
		 [(arity-at-least? a) (and (negative? max)
					   (= (arity-at-least-value a) min))]
		 [(and (list? a) (andmap integer? a))
		  (and (= min (car a)) (= max
					  (let loop ([l a])
					    (if (null? (cdr l))
						(car l)
						(loop (cdr l))))))]
		 [(list? a)
		  ;; Just check that all are consistent for now.
		  ;; This should be improved.
		  (andmap
		   (lambda (a)
		     (if (number? a)
			 (<= min a (if (negative? max) a max))
			 (>= (arity-at-least-value a) min)))
		   a)]
		 [else #f]))]
	     [make-ok?
	      (lambda (v)
		(lambda (e)
		  (exn:application:arity? e)))]
	     [do-test
	      (lambda (f args check?)
		(set! number-of-error-tests (add1 number-of-error-tests))
		(printf "(apply ~s '~s)  =e=> " f args)
		(let/ec done
		  (let ([v (with-handlers ([void
					    (lambda (exn)
					      (if (check? exn)
						  (printf " ~a\n" (if (exn? exn)
                                                                      (exn-message exn)
                                                                      (format "uncaught ~x" exn)))
						  (let ([ok-type? (exn:application:arity? exn)])
						    (printf " WRONG EXN ~a: ~s\n"
							    (if ok-type?
								"FIELD"
								"TYPE")
							    exn)
						    (record-error (list exn
									(if ok-type?
									    'exn-field
									    'exn-type)
									(cons f args)))))
					      (done (void)))])
			     (apply f args))])
		    (printf "~s\n BUT EXPECTED ERROR\n" v)
		    (record-error (list v 'Error (cons f args))))))])
      (test #t aok? (procedure-arity f))
      (let loop ([n 0][l '()])
	(unless (>= n min)
	  (unless (memq n except)
	    (do-test f l (make-ok? n)))
	  (loop (add1 n) (cons 1 l))))
      (let loop ([n min])
	(unless (memq n except)
	  (test #t procedure-arity-includes? f n))
	(unless (>= n max)
	  (loop (add1 n))))
      (if (>= max 0)
	  (do-test f (let loop ([n 0][l '(1)])
		       (if (= n max)
			   l
			   (loop (add1 n) (cons 1 l))))
		   (make-ok? (add1 max)))
	  (test #t procedure-arity-includes? f (arithmetic-shift 1 100))))]
   [(f min max) (arity-test f min max null)]))

(define (test-values l thunk)
  (test l call-with-values thunk list))

(define (report-errs . final?)
  (let* ([final? (and (pair? final?) (car final?))]
         [ok?    (null? errs)])
    (parameterize ([current-output-port
                    (cond [(not ok?) (or real-error-port (current-error-port))]
                          [final? (or real-output-port (current-output-port))]
                          [else (current-output-port)])])
      (printf "\n~aPerformed ~a expression tests (~a ~a, ~a ~a)\n"
              Section-prefix
              (+ number-of-tests number-of-error-tests)
              number-of-tests "value expressions"
              number-of-error-tests "exn expressions")
      (printf "~aand ~a exception field tests.\n\n"
              Section-prefix
              number-of-exn-tests)
      (if ok?
        (printf "~aPassed all tests.\n" Section-prefix)
        (begin (printf "~aErrors were:\n~a(Section (got expected (call)))\n"
                       Section-prefix Section-prefix)
               (for-each (lambda (l) (printf "~a~s\n" Section-prefix l))
                         (reverse errs))
               (when final? (exit 1))))
      (flush-output)
      (when final? (exit (if ok? 0 1)))
      (printf "(Other messages report successful tests of~a.)\n"
              " error-handling behavior")
      (flush-output))))

(define type? exn:application:type?)
(define arity? exn:application:arity?)
(define syntaxe? exn:fail:syntax?)

(define non-z void)

(define (find-depth go)
  ; Find depth that triggers a stack overflow (assuming no other
  ; threads are running and overflowing)
  (let ([v0 (make-vector 6)]
	[v1 (make-vector 6)])
    (let find-loop ([d 100])
      (vector-set-performance-stats! v0)
      (go d)
      (vector-set-performance-stats! v1)
      (if (> (vector-ref v1 5)
	     (vector-ref v0 5))
	  d
	  (find-loop (* 2 d))))))

(Section 'struct)

;; The full struct-test is in struct-test.rkt

;; Override super-struct procedure spec:
(let-values ([(s:s make-s s? s-ref s-set!)
              (make-struct-type 'a #f 1 1 #f null (current-inspector) 0)])
  (let-values ([(s:b make-b b? b-ref s-set!)
                (make-struct-type 'b s:s 1 1 #f null (current-inspector) 0)])
    (test 11 (make-b 1 add1) 10)))

(let-values ([(type make pred sel set) (make-struct-type 'p #f 1 0 #f null (current-inspector) (lambda () 5))])
  (let ([useless (make 7)])
    (test 'p object-name useless)))

(let-values ([(type make pred sel set) (make-struct-type 'p #f 1 0 #f null (current-inspector)
							 (case-lambda 
							  [(x) 7]
							  [() 5]
							  [(x y z) 8]))]) 
  (let ([useless (make 7)])
    (test 'p object-name useless)))

;; ----------------------------------------

(report-errs)