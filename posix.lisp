(in-package #:org.shirakumo.machine-state)

(cffi:defcvar (errno "errno") :int64)

(defun strerror ()
  (cffi:foreign-funcall "strerror" :int64 errno :string))

(defmacro posix-call (function &rest args)
  `(let ((val (cffi:foreign-funcall ,function ,@args)))
     (if (< val 0)
         (fail (strerror))
         val)))

(defmacro posix-call0 (function &rest args)
  `(let ((val (cffi:foreign-funcall ,function ,@args)))
     (if (/= 0 val)
         (fail (strerror))
         val)))

(cffi:defcstruct (timeval :conc-name timeval-)
  (sec :uint64)
  (usec :uint64))

(cffi:defcstruct (rusage :conc-name rusage-)
  (utime (:struct timeval))
  (stime (:struct timeval))
  ;; Linux fields
  (maxrss :long)
  (ixrss :long)
  (idrss :long)
  (isrss :long)
  (minflt :long)
  (majflt :long)
  (nswap :long)
  (inblock :long)
  (oublock :long)
  (msgsnd :long)
  (msgrcv :long)
  (nsignals :long)
  (nvcsw :long)
  (nivcsw :long))

(define-implementation process-room ()
  (cffi:with-foreign-object (rusage '(:struct rusage))
    (posix-call "getrusage" :int 0 :pointer rusage :int)
    (* 1024 (+ (rusage-ixrss rusage)
               (rusage-idrss rusage)
               (rusage-isrss rusage)))))

(define-implementation process-time ()
  (cffi:with-foreign-object (rusage '(:struct rusage))
    (posix-call "getrusage" :int 0 :pointer rusage :int)
    (+ (timeval-sec rusage)
       (* (timeval-usec rusage) 10d-7))))

(cffi:defcstruct (sysinfo :conc-name sysinfo-)
  (uptime :long)
  (loads :ulong :count 3)
  (total-ram :ulong)
  (free-ram :ulong)
  (shared-ram :ulong)
  (buffer-ram :ulong)
  (total-swap :ulong)
  (free-swap :ulong)
  (processes :ushort)
  (total-high :ulong)
  (free-high :ulong)
  (memory-unit :uint)
  (_pad :char :count 22))

#-darwin
(define-implementation machine-room ()
  (cffi:with-foreign-objects ((sysinfo '(:struct sysinfo)))
    (posix-call "sysinfo" :pointer sysinfo :int)
    (let ((total (sysinfo-total-ram sysinfo))
          (free (sysinfo-free-ram sysinfo)))
      (values (- total free) total))))

#-darwin
(define-implementation machine-uptime ()
  (cffi:with-foreign-objects ((sysinfo '(:struct sysinfo)))
    (posix-call "sysinfo" :pointer sysinfo :int)
    (sysinfo-uptime sysinfo)))

#-darwin
(define-implementation machine-cores ()
  ;; _SC_NPROCESSORS_ONLN 84
  (posix-call "sysconf" :int 84 :long))

(defmacro with-thread-handle ((handle thread &optional (default 0)) &body body)
  `(if (or (eql ,thread T)
           (eql ,thread (bt:current-thread)))
       (let ((,handle (cffi:foreign-funcall "pthread_self" :pointer)))
         (declare (ignorable ,handle))
         ,@body)
       ,default))

(define-implementation thread-time (thread)
  (with-thread-handle (handle thread 0d0)
    (cffi:with-foreign-object (rusage '(:struct rusage))
      (posix-call "getrusage" :int 1 :pointer rusage :int)
      (+ (timeval-sec rusage)
         (* (timeval-usec rusage) 10d-7)))))

(define-implementation thread-core-mask (thread)
  (with-thread-handle (handle thread (1- (ash 1 (machine-cores))))
    (cffi:with-foreign-objects ((cpuset :uint64))
      (posix-call0 "pthread_getaffinity_np" :pointer handle :size (cffi:foreign-type-size :uint64) :pointer cpuset :int)
      (cffi:mem-ref cpuset :uint64))))

(define-implementation (setf thread-core-mask) (mask thread)
  (with-thread-handle (handle thread (1- (ash 1 (machine-cores))))
    (cffi:with-foreign-objects ((cpuset :uint64))
      (setf (cffi:mem-ref cpuset :uint64) mask)
      (posix-call0 "pthread_setaffinity_np" :pointer handle :size (cffi:foreign-type-size :uint64) :pointer cpuset :int)
      (cffi:mem-ref cpuset :uint64))))

(define-implementation process-priority ()
  (let ((err errno)
        (value (cffi:foreign-funcall "getpriority" :int 0 :uint32 0 :int)))
    (when (and (= -1 value) (/= err errno))
      (fail (cffi:foreign-funcall "strerror" :int64 errno)))
    (cond ((< value -8) :realtime)
          ((< value  0) :high)
          ((= value  0) :normal)
          ((< value +8) :low)
          (T :idle))))

(define-implementation (setf process-priority) (priority)
  (let ((prio (ecase priority
                (:idle      19)
                (:low        5)
                (:normal     0)
                (:high      -5)
                (:realtime -20))))
    (posix-call0 "setpriority" :int 0 :uint32 0 :int prio :int))
  priority)

(define-implementation thread-priority (thread)
  (with-thread-handle (handle thread :normal)
    (cffi:with-foreign-objects ((policy :int)
                                (param :int))
      (posix-call0 "pthread_getschedparam" :pointer handle :pointer policy :pointer param :int)
      (let ((priority (cffi:mem-ref param :int)))
        (cond ((< priority 20) :idle)
              ((< priority 50) :low)
              ((= priority 50) :normal)
              ((< priority 70) :high)
              (T :realtime))))))

(define-implementation (setf thread-priority) (thread priority)
  (with-thread-handle (handle thread :normal)
    (cffi:with-foreign-objects ((policy :int)
                                (param :int))
      (posix-call0 "pthread_getschedparam" :pointer handle :pointer policy :pointer param :int)
      (let ((policy (cffi:mem-ref policy :int)))
        (setf (cffi:mem-ref param :int) (ecase priority
                                          (:idle      1)
                                          (:low      40)
                                          (:normal   50)
                                          (:high     60)
                                          (:realtime 99)))
        (posix-call0 "pthread_setschedparam" :pointer handle :int policy :pointer param :int)))
    priority))

(define-implementation network-info ()
  (cffi:with-foreign-object (hostname :char 512)
    (posix-call "gethostname" :pointer hostname :size 512 :int)
    (cffi:foreign-string-to-lisp hostname :max-chars 512)))

(define-protocol-fun self () (pathname)
  *default-pathname-defaults*)

(define-implementation process-info ()
  (values
   (self)
   (pathname-utils:parse-native-namestring
    (cffi:with-foreign-object (path :char 1024)
      (cffi:foreign-funcall "getcwd" :pointer path :size 1024)
      (cffi:foreign-string-to-lisp path :max-chars 1024))
    :as :directory)
   (cffi:foreign-funcall "getlogin" :string)
   (let ((gid (cffi:foreign-funcall "getpwuid" :size (cffi:foreign-funcall "getgid" :size) :pointer)))
     (if (cffi:null-pointer-p gid)
         "Unknown"
         (cffi:mem-ref gid :string)))))
