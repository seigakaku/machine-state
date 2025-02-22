(in-package #:org.shirakumo.machine-state)

(defmacro with-gensyms (syms &body body)
  `(let ,(mapcar (lambda (sym) `(,sym (gensym (symbol-name ',sym)))) syms)
     ,@body))

#-openbsd
(cffi:defcvar (errno "errno") :int64)

(defun strncmp-lisp (foreign-str lisp-str &key (max-chars (length lisp-str)))
  (= 0 (cffi:foreign-funcall "strncmp" :pointer foreign-str :string lisp-str :size max-chars :int)))

(defun errno ()
  #-openbsd errno
  ;; errno is a thread local in openbsd, simple (defcvar errno) won't work
  ;; https://github.com/openbsd/src/blob/master/lib/libc/gen/errno.c#L57
  ;; https://github.com/openbsd/src/blob/master/include/errno.h#L54
  #+openbsd (cffi:mem-ref (cffi:foreign-funcall "__errno" (:pointer :int)) :int))

(defun strerror (&optional (errno (errno)))
  (cffi:foreign-funcall "strerror" :int errno :string))

(defmacro posix-call (function &rest args)
  (with-gensyms (%val)
    `(let ((,%val (cffi:foreign-funcall ,function ,@args)))
       (if (< ,%val 0)
           (fail (strerror) ,function)
           ,%val))))

#+freebsd
(progn
  (defun count-fields (str separator)
    (reduce (lambda (count ch)
              (if (char= ch separator)
                  (1+ count)
                  count))
            str
            :initial-value 1))

  (defun sysctl-name-to-mib (name &optional (mibn (count-fields name #\.)))
    (cffi:with-foreign-objects ((mibp :int mibn) (sizep :size))
      (setf (cffi:mem-ref sizep :size) mibn)
      (cffi:foreign-funcall "sysctlnametomib" :string name (:pointer :int) mibp (:pointer :size) sizep)
      (loop for i below mibn collect (cffi:mem-aref mibp :int i))))

  (defun sysctl-resolve-mib (mib)
    (etypecase mib
      (string (sysctl-name-to-mib mib))
      (list (mapcan (lambda (x)
                      (etypecase x
                        (string (sysctl-name-to-mib x))
                        (number (list x))))
                    mib)))))

#+openbsd
(defun sysctl-resolve-mib (mib) mib)

(cffi:defcfun ("sysctl" c-sysctl) :int
  (mib (:pointer :int))
  (mibn :uint)
  (old :pointer)
  (oldlen (:pointer :size))
  (new :pointer)
  (newlen :size))

(defun sysctl (mib out out-size &optional (handle-error t))
  (setf mib (sysctl-resolve-mib mib))
  (let ((mibn (length mib)))

    (cffi:with-foreign-objects ((%mib :int mibn) (oldlen :size))
      (loop
        for name in mib and i from 0
        do (setf (cffi:mem-aref %mib :int i) name))

      (when out
        (setf (cffi:mem-ref oldlen :size) out-size))

      (let ((ret (c-sysctl %mib mibn (or out (cffi:null-pointer)) oldlen (cffi:null-pointer) 0)))
        (when (and handle-error (< ret 0))
          (fail (strerror) "sysctl"))
        (values (or out (cffi:mem-ref oldlen :int)) ret)))))

(defmacro with-sysctl ((mib out type &optional (count 1)) &body body)
  "Utility for SYSCTL, MIB is evaluated into a list."
  (with-gensyms (%mib %count)
    `(let* ((,%mib ,(etypecase mib
                      (list `(list ,@mib))
                      (string `(list ,mib))
                      (t mib)))
            (,%count ,count))
       (cffi:with-foreign-object (,out ,type ,%count)
         (sysctl ,%mib ,out (* ,%count (cffi:foreign-type-size ,type)))
         ,@body))))

(defmacro with-sysctls ((&rest sysctls) &body body)
  "Like with sysctl, but allows for multiple at once."
  (if sysctls
      `(with-sysctl (,@(car sysctls))
         (with-sysctls (,@(cdr sysctls)) ,@body))
      `(progn ,@body)))

(defun sysctl-unchecked (mib out out-size)
  "Like SYSCTL but don't handle the ERRNO, the return value of SYSCTL is in the second value.
 Useful for when ERRNO has special meanings."
  (sysctl mib out out-size nil))

(defun sysctl-size (mib)
  "Call sysctl for the size of what would be returned with MIB, in bytes"
  (sysctl mib nil nil t))

(defun sysctl-ref (mib type &optional (offset 0))
  (with-sysctl (mib out type)
    (cffi:mem-ref out type offset)))

(defun sysctl-string (mib size)
  "Like SYSCTL but return a string of SIZE characters."
  (with-sysctl (mib str :char size)
    (cffi:foreign-string-to-lisp str :max-chars size)))

#+32-bit
(cffi:defcstruct (timeval :conc-name timeval-)
  (sec :uint32)
  (usec :uint32))

#+64-bit
(cffi:defcstruct (timeval :conc-name timeval-)
  (sec :uint64)
  (usec :uint64))

(defun timeval->seconds (tv)
  (+ (timeval-sec tv)
     (/ (timeval-usec tv) 1000000.0d0)))

(defconstant +unix-epoch+ (encode-universal-time 0 0 0 1 1 1970 0))
(defun get-unix-time () (- (get-universal-time) +unix-epoch+))

;;;; https://github.com/freebsd/freebsd-src/blob/main/sys/sys/time.h#L480
;;;; https://github.com/openbsd/src/blob/master/sys/sys/time.h#L157
(cffi:defcstruct (clockinfo :size #+openbsd 16
                                  #+freebsd 20 ;; FreeBSD has a reserved field
                            :conc-name clockinfo-)
  (hz :int))

(defun getpid () (cffi:foreign-funcall "getpid" :long)) ;; pid_t
(defun page-size () (cffi:foreign-funcall "getpagesize" :int))

(defconstant +maxcomlen+
  #+openbsd 24 ;; Actually _MAXCOMLEN, https://github.com/openbsd/src/blob/master/sys/sys/sysctl.h#L363
  #+freebsd 19) ;; https://github.com/freebsd/freebsd-src/blob/main/sys/sys/param.h#L125

(defun process-nice->priority (value)
  (cond ((< value -8) :realtime)
        ((< value  0) :high)
        ((= value  0) :normal)
        ((< value +8) :low)
        (T :idle)))

(defun priority->process-nice (priority)
  (ecase priority
    (:idle      19)
    (:low        5)
    (:normal     0)
    (:high      -5)
    (:realtime -20)))

(defun split-path (path &optional (delimiter #\:))
  (let (paths start)
    (do ((i 0 (1+ i)))
        ((= i (length path)) (nreverse paths))
      (when (char= (schar path i) delimiter)
        (push (subseq path (or start 0) i) paths)
        (setf start (1+ i))))))

(defun resolve-executable (command)
  (let ((path (cffi:foreign-funcall "getenv" :string "PATH" :string)))
    (when path
      (dolist (dir (split-path path #\:))
        (let ((exec-path (make-pathname
                          :defaults (pathname-utils:parse-native-namestring dir :as :directory)
                          :name command)))
          (when (probe-file exec-path)
            (return-from resolve-executable exec-path)))))))

(defun uid->user (uid) (cffi:foreign-funcall "user_from_uid" :uint32 uid :int 1 :string))
(defun gid->group (gid) (cffi:foreign-funcall "group_from_gid" :uint32 gid :int 1 :string))

#+openbsd
(cffi:defcstruct (stat :size #+32-bit 108
                             #+64-bit 128
                       :conc-name stat-)
  (mode :int :offset 0) ;; st_mode
  (dev :int :offset 4)) ;; st_dev

#+freebsd
(cffi:defcstruct (stat :size #+64-bit 224
                             #+32-bit 208
                       :conc-name stat-)
  (dev :int :offset 0) ;; st_dev
  (mode :int :offset 24)) ;; st_mode

(defconstant +mnt-wait+ 1)
(defconstant +mnt-nowait+ 2)

(defun pathname-force-file (path)
  (cond
    ((pathname-utils:root-p path) path)
    ((pathname-utils:file-p path) path)
    (T (let ((directories (pathname-directory path)))
         (make-pathname :defaults path
                        :directory (butlast directories)
                        :name (car (last directories)))))))

(defun find-mount-root (path)
  (labels ((dev-id (path)
             (cffi:with-foreign-objects ((stat '(:struct stat)))
               (posix-call "stat" :string (pathname-utils:native-namestring path) :pointer stat :int)
               (stat-dev stat)))
           (rec (path &optional (id (dev-id path)))
             (if (pathname-utils:root-p path)
                 path
                 (let* ((parent (pathname-utils:parent path))
                        (parent-id (dev-id parent)))
                   (if (= parent-id id)
                       (rec parent parent-id)
                       path)))))
    (pathname-force-file (rec (truename path)))))

(defun getfsstat (buf &optional (count 0) (wait? t))
  (let* ((flags (if wait? +mnt-wait+ +mnt-nowait+))
         (bufsize (* count (cffi:foreign-type-size '(:struct statfs)))))
    (posix-call "getfsstat" :pointer (or buf (cffi:null-pointer)) :size bufsize :int flags :int)))

(defun mount-count ()
  (getfsstat nil))

(defmacro do-filesystems ((fs) &body body)
  (with-gensyms (statfs count i)
    `(let ((,count (mount-count)))
       (cffi:with-foreign-object (,statfs '(:struct statfs) ,count)
         (getfsstat ,statfs ,count)
         (or (dotimes (,i ,count)
               (let ((,fs (cffi:mem-aptr ,statfs '(:struct statfs) ,i)))
                 ,@body))
             (fail "Filesystem not found"))))))

;;;; https://github.com/openbsd/src/blob/master/include/ifaddrs.h#L31
;;;; https://github.com/freebsd/freebsd-src/blob/main/include/ifaddrs.h#L32
(cffi:defcstruct (ifaddrs :conc-name ifaddrs-)
  (next (:pointer (:struct ifaddrs))) ;; ifa_next
  (name :string) ;; ifa_name
  (flags :uint) ;; ifa_flags
  (address :pointer) ;; ifa_addr
  (netmask :pointer) ;; ifa_netmask
  (destination :pointer) ;; ifa_dstaddr/ifa_broadaddr
  (data :pointer)) ;; ifa_data

(cffi:defcstruct (sockaddr :conc-name sockaddr-)
  (length :uint8) ;; sa_len
  (family :uint8) ;; sa_family
  (data (:array :char 14))) ;; sa_data

(cffi:defcstruct (sockaddr-dl :size #+openbsd 32
                                    #+freebsd 54
                              :conc-name sockaddr-dl-)
  (interface-name-length :unsigned-char :offset 5) ;; sdl_nlen
  (address-length :unsigned-char :offset 6) ;; sdl_alen
  (data (:array :unsigned-char #+openbsd 24 #+freebsd 46) :offset 8)) ;; sdl_data

(defun sockaddr-dl-address (dl)
  (let* ((addr-start (sockaddr-dl-interface-name-length dl))
         (addr-length (sockaddr-dl-address-length dl)))
    (if (= 0 addr-length)
        nil
        (subseq (sockaddr-dl-data dl) addr-start (+ addr-start addr-length)))))

(cffi:defcstruct (sockaddr4 :size 16 :conc-name sockaddr4-)
  (family :ushort :offset 1)
  (port :uint16 :offset 2)
  (addr (:array :uint8 4) :offset 4))

;;;; https://github.com/freebsd/freebsd-src/blob/main/sys/netinet6/in6.h#L128
(cffi:defcstruct (sockaddr6 :size 28 :conc-name sockaddr6-)
  (family :ushort :offset 1)
  (port :uint16 :offset 2)
  (addr (:array :uint8 16) :offset 8))

(defconstant +af-link+ 18)
(defconstant +af-inet+ 2)
(defconstant +af-inet6+ #+openbsd 24 #+freebsd 28)

(defmacro do-ifaddrs ((ifaptr) &body body)
  (with-gensyms (ifap)
    `(cffi:with-foreign-object (,ifap :pointer)
       (posix-call "getifaddrs" :pointer ,ifap :int)
       (let ((,ifap (cffi:mem-ref ,ifap :pointer)))
         (unwind-protect
              (do ((,ifaptr ,ifap (ifaddrs-next ,ifaptr)))
                  ((cffi:null-pointer-p ,ifaptr) nil)
                ,@body)
           (cffi:foreign-funcall "freeifaddrs" :pointer ,ifap))))))

(define-implementation network-devices ()
  (let ((names nil))
    (do-ifaddrs (ifaddr)
      (pushnew (ifaddrs-name ifaddr) names :test #'string=))
    (nreverse names)))

(defun ipv4->string (ipv4)
  (format nil "~{~d~^.~}" (coerce ipv4 'list)))

(defun macaddr->string (macaddr)
  (format nil "~{~2,'0x~^:~}" (coerce macaddr 'list)))

(defun ipv6->string (ipv6)
  (labels ((fmt-byte (x) (format nil "~2,'0x" x))
           (fmt-segment (x y) (format nil "~a~a" (fmt-byte x) (fmt-byte y))))
    (format nil "~{~a~^:~}"
            (loop
              for (x y) on (coerce ipv6 'list) by #'cddr
              collect (fmt-segment x y)))))

(define-implementation network-address (device)
  (let (ipv4 ipv6 mac)
    (do-ifaddrs (ifaddr)
      (when (string= device (ifaddrs-name ifaddr))
        (let* ((sockaddr (ifaddrs-address ifaddr))
               (address-family (sockaddr-family sockaddr)))
          (case address-family
            (#.+af-inet+ (unless ipv4 (setf ipv4 (ipv4->string (sockaddr4-addr sockaddr)))))
            (#.+af-inet6+ (unless ipv6 (setf ipv6 (ipv6->string (sockaddr6-addr sockaddr)))))
            (#.+af-link+
             (unless mac
               (let ((addr (sockaddr-dl-address sockaddr)))
                 (when addr
                   (setf mac (macaddr->string addr))))))))))
    (values ipv4 ipv6 mac)))

(defconstant +o-rdonly+ 0)
(defconstant +o-wronly+ 1)
(defconstant +o-rdwr+ 2)

(defmacro with-fd ((fd file &key (direction :input)) &body body)
  `(let ((,fd (posix-call "open"
                          :string (pathname-utils:native-namestring ,file)
                          :int ,(ecase direction
                                  (:input +o-rdonly+)
                                  (:output +o-wronly+)
                                  (:io +o-rdwr+))
                          :int)))
     (unwind-protect
          (progn ,@body)
       (posix-call "close" :int ,fd :int))))
