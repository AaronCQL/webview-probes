package main

/*
#cgo CFLAGS: -I${SRCDIR}/../include -DPM_NO_GO_DECL
#include <stdlib.h>
#include "probe_module.h"
void pm_go_fire(const pm_host *h, uint64_t id, int64_t v);
const pm_module *pm_go_table(void);
*/
import "C"

import (
	"runtime/cgo"
	"unsafe"
)

func main() {}

//export probe_go_module
func probe_go_module() *C.pm_module { return C.pm_go_table() }

//export pm_go_add
func pm_go_add(a, b C.int64_t) C.int64_t { return a + b }

//export pm_go_reverse
func pm_go_reverse(s *C.uint8_t, n C.size_t, out **C.uint8_t, outLen *C.size_t) C.int32_t {
	var in []byte
	if n > 0 {
		in = C.GoBytes(unsafe.Pointer(s), C.int(n))
	}
	r := []rune(string(in))
	for i, j := 0, len(r)-1; i < j; i, j = i+1, j-1 {
		r[i], r[j] = r[j], r[i]
	}
	b := []byte(string(r))
	size := len(b)
	if size == 0 {
		size = 1
	}
	p := (*C.uint8_t)(C.malloc(C.size_t(size)))
	copy(unsafe.Slice((*byte)(unsafe.Pointer(p)), size), b)
	*out = p
	*outLen = C.size_t(len(b))
	return 0
}

//export pm_go_free_bytes
func pm_go_free_bytes(p *C.uint8_t, n C.size_t) { C.free(unsafe.Pointer(p)) }

type counter struct{ v int64 }

//export pm_go_counter_new
func pm_go_counter_new(start C.int64_t) C.uintptr_t {
	return C.uintptr_t(cgo.NewHandle(&counter{v: int64(start)}))
}

//export pm_go_count_to
func pm_go_count_to(h C.uintptr_t, target C.int64_t, host *C.pm_host, cb C.uint64_t) C.int64_t {
	c := cgo.Handle(h).Value().(*counter)
	var calls C.int64_t
	for c.v < int64(target) {
		c.v++
		C.pm_go_fire(host, cb, C.int64_t(c.v))
		calls++
	}
	return calls
}

//export pm_go_counter_free
func pm_go_counter_free(h C.uintptr_t) { cgo.Handle(h).Delete() }
