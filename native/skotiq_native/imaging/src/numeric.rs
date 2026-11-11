//! Small numeric building blocks shared by the fitters.

/// Solve the dense `n × n` system `a · x = b` by Gaussian elimination with
/// partial pivoting. `a` is row-major. `None` when a pivot's magnitude is
/// below `singular_below`: the system has no stable solution at the caller's
/// scale.
pub(crate) fn solve_dense(
    mut a: Vec<f64>,
    mut b: Vec<f64>,
    singular_below: f64,
) -> Option<Vec<f64>> {
    let n = b.len();
    if a.len() != n * n {
        return None;
    }
    for col in 0..n {
        let mut pivot = col;
        let mut largest = a[col * n + col].abs();
        for row in (col + 1)..n {
            let candidate = a[row * n + col].abs();
            if candidate > largest {
                largest = candidate;
                pivot = row;
            }
        }
        if largest < singular_below {
            return None;
        }
        if pivot != col {
            for k in 0..n {
                a.swap(col * n + k, pivot * n + k);
            }
            b.swap(col, pivot);
        }
        let pivot_value = a[col * n + col];
        for row in (col + 1)..n {
            let factor = a[row * n + col] / pivot_value;
            if factor != 0.0 {
                for k in col..n {
                    a[row * n + k] -= factor * a[col * n + k];
                }
                b[row] -= factor * b[col];
            }
        }
    }
    let mut x = vec![0.0; n];
    for row in (0..n).rev() {
        let mut sum = b[row];
        for k in (row + 1)..n {
            sum -= a[row * n + k] * x[k];
        }
        x[row] = sum / a[row * n + row];
    }
    Some(x)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_dense_system_is_solved_and_a_singular_one_refused() {
        // 2x + y = 5, x + 3y = 10  ->  x = 1, y = 3.
        let x = solve_dense(vec![2.0, 1.0, 1.0, 3.0], vec![5.0, 10.0], 1e-12).unwrap();
        assert!((x[0] - 1.0).abs() < 1e-14 && (x[1] - 3.0).abs() < 1e-14);
        // A zero on the diagonal needs the pivot.
        let x = solve_dense(vec![0.0, 1.0, 1.0, 0.0], vec![2.0, 7.0], 1e-12).unwrap();
        assert_eq!(x, [7.0, 2.0]);
        assert!(solve_dense(vec![1.0, 2.0, 2.0, 4.0], vec![1.0, 2.0], 1e-12).is_none());
        assert!(solve_dense(vec![1.0; 3], vec![1.0, 2.0], 1e-12).is_none());
        assert_eq!(solve_dense(Vec::new(), Vec::new(), 1e-12), Some(Vec::new()));
    }
}
