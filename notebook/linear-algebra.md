# Linear algebra

## Connections

- [[00-start-here|Notebook guide]]
- [[spectral-theorem.tex|Spectral theorem and proof]]

## A useful question

Why do symmetric matrices have real eigenvalues?

Let $A=A^\mathsf{T}$ be real and $Av=\lambda v$ with $v\ne0$ in
$\mathbb{C}^n$. Then $v^*Av = \lambda v^*v$ is real because $A$ is Hermitian,
so $\lambda\in\mathbb{R}$.

## Experiment

```python
# Check two orthogonal eigenvectors without additional packages.
A = [[2, 1], [1, 2]]
for vector in ([1, 1], [1, -1]):
    result = [sum(a*x for a, x in zip(row, vector)) for row in A]
    print(f"A @ {vector} = {result}")
```

## Next

- [ ] Connect orthogonality to diagonalisation.
- [ ] Write a proof using an invariant orthogonal complement.
