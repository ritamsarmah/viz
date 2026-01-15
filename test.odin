package main

import "core:testing"

@(test)
test_bit_reverse_4bit :: proc(t: ^testing.T) {
	actual := bit_reverse(0b0011, 4)
	testing.expect_value(t, actual, 0b1100)
}

@(test)
test_bit_reverse_16bit :: proc(t: ^testing.T) {
	actual := bit_reverse(0b0110111011010001, 16)
	testing.expect_value(t, actual, 0b1000101101110110)
}

@(test)
test_bit_reverse_equal :: proc(t: ^testing.T) {
	actual := bit_reverse(0b10000001, 8)
	testing.expect_value(t, actual, 0b10000001)
}

@(test)
test_bit_reverse_permutation_small :: proc(t: ^testing.T) {
	data := [4]f32{1, 2, 3, 4}
	bit_reversal_permutation(data[:])

	testing.expect_value(t, data, [4]f32{1, 3, 2, 4})
}

@(test)
test_bit_reverse_permutation_large :: proc(t: ^testing.T) {
	data := [16]f32{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
	bit_reversal_permutation(data[:])

	testing.expect_value(t, data, [16]f32{1, 9, 5, 13, 3, 11, 7, 15, 2, 10, 6, 14, 4, 12, 8, 16})
}
