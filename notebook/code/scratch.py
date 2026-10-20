"""Open with Space ne (file browser), then Space rr to run."""
from fractions import Fraction

partial_sum = sum(Fraction(1, n * n) for n in range(1, 11))
print("Sum of 1/n² for n=1..10:", partial_sum)
print("As a decimal:", float(partial_sum))
