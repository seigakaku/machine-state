(in-package #:org.shirakumo.machine-state)

(defmacro nxgl-call (func &rest args)
  `(when (= 0 (cffi:foreign-funcall ,func ,@args :int))
     (fail)))

(define-implementation process-room ()
  (cffi:with-foreign-objects ((free :size) (total :size))
    (nxgl-call "nxgl_ram" :pointer free :pointer total)
    (- (cffi:mem-ref total :size) (cffi:mem-ref free :size))))

(define-implementation machine-room ()
  (cffi:with-foreign-objects ((free :size) (total :size))
    (nxgl-call "nxgl_ram" :pointer free :pointer total)
    (values (- (cffi:mem-ref total :size) (cffi:mem-ref free :size))
            (cffi:mem-ref total :size))))

(define-implementation machine-cores ()
  (cffi:foreign-funcall "nxgl_core_count" :int))

(defmacro with-thread-handle ((handle thread &optional (default 0)) &body body)
  `(if (or (eql ,thread T)
           (eql ,thread (bt:current-thread)))
       (let ((,handle (cffi:null-pointer)))
         ,@body)
       ,default))

(define-implementation thread-core-mask (thread)
  (with-thread-handle (handle thread (1- (ash 1 (machine-cores))))
    (cffi:with-foreign-objects ((mask :uint64))
      (nxgl-call "nxgl_get_core_mask" :pointer handle :pointer mask)
      (cffi:mem-ref mask :uint64))))

(define-implementation (setf thread-core-mask) (mask-int thread)
  (with-thread-handle (handle thread (1- (ash 1 (machine-cores))))
    (cffi:with-foreign-objects ((mask :uint64))
      (setf (cffi:mem-ref mask :uint64) mask-int)
      (nxgl-call "nxgl_set_core_mask" :pointer handle :pointer mask)
      (cffi:mem-ref mask :uint64))))

(define-implementation gpu-room ()
  (cffi:with-foreign-objects ((free :size) (total :size))
    (nxgl-call "nxgl_vram" :pointer free :pointer total)
    (values (cffi:mem-ref free :size)
            (cffi:mem-ref total :size))))
